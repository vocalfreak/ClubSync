# The extraction stage service (plan §6). Follows MediaProcessor's pattern:
# `Extractor.call(post, **kwargs)`, injectable collaborators, and a
# `Result(status, error, error_kind)`. The Gemini call happens outside any DB
# transaction; only the success writes are one short transaction.
#
# Error handling follows the two-tier rule (§5.2): Gemini's whole-service
# classes and the expected this-post failures are rescued into a `:failed`
# Result (writing a failed `extractions` row) and never raise. Anything else
# (a bug) raises, and AccountPipeline's per-post rescue handles it.
class Extractor
  Result = Struct.new(:status, :error, :error_kind, keyword_init: true) do
    def success?
      status == :success
    end

    def skipped?
      status == :skipped
    end

    def failed?
      status == :failed
    end
  end

  WHOLE_SERVICE_ERRORS = [
    GeminiClient::TimeoutError,
    GeminiClient::RateLimitedError,
    GeminiClient::AuthError,
    GeminiClient::ServerError
  ].freeze

  THIS_POST_ERRORS = [
    GeminiClient::BlockedError,
    GeminiClient::InvalidResponseError,
    Aws::S3::Errors::ServiceError
  ].freeze

  def self.call(post, **kwargs)
    new(post, **kwargs).call
  end

  def initialize(post, client: nil, object_store: ObjectStore.new)
    @post = post
    @client = client || GeminiClient
    @object_store = object_store
  end

  def call
    return Result.new(status: :skipped) unless @post.media_processed?

    images = image_bytes
    return fail_now("post has no images to extract from", :this_post) if images.empty?

    response = call_gemini(images)
    attributes = parse_and_gate(response)

    persist_success(attributes, response)
    Result.new(status: :success)
  rescue *WHOLE_SERVICE_ERRORS => e
    fail_now("#{e.class}: #{e.message}", :whole_service)
  rescue *THIS_POST_ERRORS => e
    fail_now("#{e.class}: #{e.message}", :this_post)
  end

  private

  # Images are read via ObjectStore#get only, in position order.
  def image_bytes
    @post.images.reload.map do |image|
      { bytes: @object_store.get(image.b2_key), content_type: image.content_type }
    end
  end

  def call_gemini(images)
    contents = GeminiPayload.build(
      caption: @post.caption,
      posted_at: @post.posted_at,
      timezone: ExtractionPrompt::TIMEZONE,
      images: images
    )

    @client.extract(
      contents: contents,
      system_instruction: ExtractionPrompt.system_instruction,
      generation_config: ExtractionPrompt.generation_config
    )
  end

  def parse_and_gate(response)
    result = ExtractionParser.new.parse(response.parsed)
    unless result.valid?
      raise GeminiClient::InvalidResponseError, "invalid Gemini response: #{result.errors.join('; ')}"
    end

    ConfidenceGate.apply(result.attributes, posted_at: @post.posted_at)
  end

  def persist_success(attributes, response)
    Post.transaction do
      Extraction.create!(
        post: @post,
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
