require "vips"

# The extraction stage service (plan §6). Follows MediaProcessor's pattern:
# `Extractor.call(post, **kwargs)`, injectable collaborators, and a
# `Result(status, error, error_kind)`. The Gemini call happens outside any DB
# transaction; only the success writes are one short transaction.
#
# Error handling follows the two-tier rule (§5.2): Gemini's whole-service
# classes and the expected this-post failures are rescued into a `:failed`
# Result (writing a failed `extractions` row) and never raise. Anything else
# (a bug) raises, and AccountPipeline's per-post rescue handles it.
#
# Retry/fallback layering (plan gap §1 + §4): the transient classes
# (TimeoutError / RateLimitedError / ServerError) are retried 3 times total at
# 2s then 4s, rotating the model pool on each attempt (`GEMINI_MODEL` then
# `GEMINI_FALLBACK_MODELS`); `AuthError` and the this-post classes never
# retry. The outage tracker lives outside this service and sees one post = one
# `Result`, so its sensitivity never couples to the retry/fallback config.
class Extractor
  Result = Struct.new(:status, :error, :error_kind, :dead_lettered, keyword_init: true) do
    def success?
      status == :success
    end

    def skipped?
      status == :skipped
    end

    def failed?
      status == :failed
    end

    def dead_lettered?
      dead_lettered == true
    end
  end

  class UndecodableImageError < StandardError; end

  WHOLE_SERVICE_ERRORS = [
    GeminiClient::TimeoutError,
    GeminiClient::RateLimitedError,
    GeminiClient::AuthError,
    GeminiClient::ServerError
  ].freeze

  TRANSIENT_ERRORS = [
    GeminiClient::TimeoutError,
    GeminiClient::RateLimitedError,
    GeminiClient::ServerError
  ].freeze

  THIS_POST_ERRORS = [
    GeminiClient::BlockedError,
    GeminiClient::InvalidResponseError,
    GeminiClient::PayloadTooLargeError,
    UndecodableImageError,
    Aws::S3::Errors::ServiceError
  ].freeze

  # Backoff only rides between the retried attempts (browser-agnostic): attempt
  # 1 fires immediately, then 2s, then 4s — 3 attempts total.
  DEFAULT_RETRY_DELAYS = [ 2, 4 ].freeze

  def self.call(post, **kwargs)
    new(post, **kwargs).call
  end

  def initialize(post, client: nil, object_store: ObjectStore.new, ingestion_run_id: nil, model: nil,
                 retry_delays: DEFAULT_RETRY_DELAYS, sleeper: nil)
    @post = post
    @client = client || GeminiClient
    @object_store = object_store
    @ingestion_run_id = ingestion_run_id
    @model = model
    @retry_delays = retry_delays
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
  end

  def call
    return Result.new(status: :skipped) unless @post.media_processed?
    return Result.new(status: :skipped, dead_lettered: true) if @post.dead_lettered?

    images = image_bytes
    return fail_now("post has no images to extract from", :this_post) if images.empty?

    response = call_gemini(images)
    attributes = parse_and_apply_threshold(response)

    persist_success(apply_csrw_guard(attributes), response)
    Result.new(status: :success)
  rescue *WHOLE_SERVICE_ERRORS => e
    fail_now("#{e.class}: #{e.message}", :whole_service)
  rescue *THIS_POST_ERRORS => e
    fail_now("#{e.class}: #{e.message}", :this_post)
  end

  private

  # Images are read via ObjectStore#get only, in position order. Each buffer is
  # decode-checked locally before the round-trip so a truncated/corrupt B2 read
  # costs a this-post failure, not a wasted Gemini call.
  def image_bytes
    @post.images.reload.map do |image|
      bytes = @object_store.get(image.b2_key)
      ensure_decodeable!(bytes, image)
      { bytes: bytes, content_type: image.content_type }
    end
  end

  def ensure_decodeable!(bytes, image)
    return if decodeable?(bytes)

    raise UndecodableImageError, "undecodable image bytes read from B2 for #{image.b2_key}"
  end

  def decodeable?(bytes)
    Vips::Image.new_from_buffer(bytes, "", access: :sequential)
    true
  rescue Vips::Error
    false
  end

  # Retry loop (gap §1) fused with the model pool (gap §4): attempt i sleeps
  # the i-th backoff delay, then calls models[i % pool.size]. A transient error
  # rotates to the next model on the next attempt — 3 attempts total, after
  # which the last transient error is re-raised for the whole-service rescue.
  def call_gemini(images)
    contents = GeminiPayload.build(
      caption: @post.caption,
      posted_at: @post.posted_at,
      timezone: ExtractionPrompt::TIMEZONE,
      images: images
    )

    models = model_pool
    delays = [ 0, *@retry_delays ]
    last_error = nil

    delays.each_with_index do |delay, attempt|
      @sleeper.call(delay) if delay.positive?

      begin
        return attempt_call(contents, models[attempt % models.size])
      rescue *TRANSIENT_ERRORS => e
        last_error = e
      end
    end

    raise last_error
  end

  def attempt_call(contents, model)
    @client.extract(
      contents: contents,
      system_instruction: ExtractionPrompt.system_instruction,
      generation_config: ExtractionPrompt.generation_config,
      model: model
    )
  end

  # An explicit model (extract_pool ramp) wins and suppresses fallbacks — a
  # single-model comparison is the point there. Otherwise GEMINI_MODEL is the
  # primary and GEMINI_FALLBACK_MODELS is the comma-separated ordered fallback
  # list; both empty means the injectable client decides (test fakes).
  def model_pool
    return [ @model ] if @model

    primary = ENV["GEMINI_MODEL"].to_s.strip
    return [ nil ] if primary.empty?

    fallbacks = ENV["GEMINI_FALLBACK_MODELS"].to_s.split(",").map(&:strip).reject(&:empty?)
    [ primary, *fallbacks ]
  end

  def parse_and_apply_threshold(response)
    result = ExtractionParser.new.parse(response.parsed)
    unless result.valid?
      raise GeminiClient::InvalidResponseError, "invalid Gemini response: #{result.errors.join('; ')}"
    end

    ConfidenceThreshold.apply(result.attributes, posted_at: @post.posted_at)
  end

  # CSRW guard (2026-09-24, decided-pending-build): a caption matching
  # CsrwRetagger's markers is force-corrected to the csrw category right after
  # the LLM classification and before any `events` row is created — a csrw post
  # can never carry an event card (category→is_event is pure code) and nothing
  # is ever deleted in the live path (the one-off rake keeps destroy semantics
  # purely for repairing historical rows). Marker match wins even for a passing
  # "after CSRW" mention — recall over precision, pinned by a test. The stored
  # `raw_response` still records Gemini's own unfiltered answer.
  def apply_csrw_guard(attributes)
    return attributes unless CsrwRetagger.csrw?(@post.caption)

    attributes.merge(category: Categories::CSRW, is_event: false)
  end

  def persist_success(attributes, response)
    Post.transaction do
      Extraction.create!(
        post: @post,
        ingestion_run_id: @ingestion_run_id,
        status: "succeeded",
        model: response.model,
        prompt_version: ExtractionPrompt::VERSION,
        category: attributes[:category],
        category_confidence: attributes[:category_confidence],
        raw_response: response.parsed,
        input_tokens: response.prompt_tokens,
        output_tokens: response.candidates_tokens,
        duration_ms: response.duration_ms,
        image_count: @post.images.size
      )

      create_event(attributes) if attributes[:is_event]

      @post.update!(
        category: attributes[:category],
        is_event: attributes[:is_event],
        stage: :extracted,
        last_error: nil,
        stage_failed_at: nil
      )
    end
  end

  def create_event(attributes)
    confidence = attributes[:confidence]
    Event.create!(
      post: @post,
      title: attributes[:title],
      starts_on: attributes[:starts_date],
      starts_time: attributes[:starts_time],
      ends_on: attributes[:ends_date],
      ends_time: attributes[:ends_time],
      venue: attributes[:venue],
      registration_url: attributes[:registration_url],
      details: details_hash(attributes),
      title_confidence: confidence[:title] || 0.0,
      starts_at_confidence: confidence[:starts_at] || 0.0,
      venue_confidence: confidence[:venue] || 0.0
    )
  end

  def details_hash(attributes)
    details = {}
    details["members_only"] = attributes[:members_only] unless attributes[:members_only].nil?
    details["online_only"] = attributes[:online_only] unless attributes[:online_only].nil?
    details["registration_via"] = attributes[:registration_via] unless attributes[:registration_via].nil?
    details["notes"] = attributes[:notes] unless attributes[:notes].nil?
    details
  end

  # Failure: never raises (defensive against the DB write itself failing);
  # writes the record of why the post is stuck, stage stays media_processed.
  def fail_now(message, error_kind)
    @post.update(last_error: message, stage_failed_at: Time.current)
    Extraction.create!(
      post: @post,
      ingestion_run_id: @ingestion_run_id,
      status: "failed",
      error_kind: error_kind.to_s,
      error: message,
      prompt_version: ExtractionPrompt::VERSION,
      image_count: @post.images.size
    )
    Result.new(status: :failed, error: message, error_kind: error_kind)
  rescue StandardError
    Result.new(status: :failed, error: message, error_kind: error_kind)
  end
end
