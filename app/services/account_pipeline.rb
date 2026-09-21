require "net/http"

class AccountPipeline
  Result = Struct.new(:success, :errors, :posts_scraped, :stage_results, :unexpected_errors, keyword_init: true) do
    def success?
      success
    end
  end

  def self.call(account, ingestion_run_id: nil, breaker: nil, gemini_client: nil)
    new.call(account, ingestion_run_id: ingestion_run_id, breaker: breaker, gemini_client: gemini_client)
  end

  def call(account, ingestion_run_id: nil, breaker: nil, gemini_client: nil)
    @breaker = breaker
    @gemini_client = gemini_client
    @posts_scraped = 0
    @stage_results = {}
    @unexpected_errors = 0

    begin
      posts = ApifyClient.fetch_account(account.handle)
    rescue ApifyClient::TimeoutError, ApifyClient::RateLimitedError, Net::OpenTimeout => e
      return Result.new(success: false, errors: [ e.message ], posts_scraped: 0, stage_results: {}, unexpected_errors: 0)
    end

    posts.each do |raw|
      @posts_scraped += 1
      adapter_result = Adapters::Apify::PostAdapter.new.parse_post(raw)
      loader_result = PostLoader.call(adapter_result, ingestion_run_id: ingestion_run_id)
      next if loader_result.no_row? || loader_result.skipped?

      process_post(loader_result.post, raw)
    end

    Result.new(success: true, errors: [], posts_scraped: @posts_scraped, stage_results: @stage_results, unexpected_errors: @unexpected_errors)
  end

  private

  def process_post(post, raw)
    if post.scraped? && supported_type?(post)
      tally(:media_processed, MediaProcessor.call(post, raw_payload: raw))
    end

    if post.media_processed? && !@breaker&.open?
      extraction = Extractor.call(post, client: @gemini_client)
      tally(:extracted, extraction)
      @breaker&.record(extraction)
    end
  rescue StandardError => e
    record_unexpected(post, e)
  end

  def supported_type?(post)
    %w[Image Sidecar].include?(post.post_type)
  end

  # Only succeeded/failed are tallied; :skipped means the post was already
  # past the stage and contributes nothing to the run's stage breakdown.
  def tally(stage, result)
    return if result.skipped?

    @stage_results[stage.to_s] ||= {}
    outcome = result.success? ? "succeeded" : "failed"
    @stage_results[stage.to_s][outcome] = @stage_results[stage.to_s].fetch(outcome, 0) + 1
  end

  # The one per-post rescue. A post-level bug records "Unexpected ..." and
  # never aborts the rest of the run; the count surfaces in the Discord summary.
  def record_unexpected(post, error)
    @unexpected_errors += 1
    Rails.logger.error(
      "AccountPipeline: unexpected error on post #{post.shortcode}: #{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}"
    )
    post.update(last_error: "Unexpected #{error.class}: #{error.message}", stage_failed_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("AccountPipeline: failed to record unexpected error: #{e.class}: #{e.message}")
  end
end
