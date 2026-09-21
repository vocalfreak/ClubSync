require "net/http"

class AccountPipeline
  Result = Struct.new(:success, :errors, :posts_scraped, keyword_init: true) do
    def success?
      success
    end
  end

  def self.call(account, ingestion_run_id: nil)
    new.call(account, ingestion_run_id: ingestion_run_id)
  end

  def call(account, ingestion_run_id: nil)
    posts_scraped = 0

    begin
      posts = ApifyClient.fetch_account(account.handle)
    rescue ApifyClient::TimeoutError, ApifyClient::RateLimitedError, Net::OpenTimeout => e
      return Result.new(success: false, errors: [ e.message ], posts_scraped: 0)
    end

    posts.each do |raw|
      posts_scraped += 1
      adapter_result = Adapters::Apify::PostAdapter.new.parse_post(raw)
      loader_result = PostLoader.call(adapter_result, ingestion_run_id: ingestion_run_id)

      if should_process_media?(loader_result)
        MediaProcessor.call(loader_result.post, raw_payload: raw)
      end
    end

    Result.new(success: true, errors: [], posts_scraped: posts_scraped)
  end

  private

  def should_process_media?(loader_result)
    return false if loader_result.no_row? || loader_result.skipped?

    post = loader_result.post
    post.scraped? && %w[Image Sidecar].include?(post.post_type)
  end
end
