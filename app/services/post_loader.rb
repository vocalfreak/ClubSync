# Update/Insers a Post row from adapter Result object
# Owns every write to `posts`
# Never advances `stage` past `scraped`, and never
# touches `is_event`/`last_error`/`stage_failed_at` — those belong to
# the stage-services (MediaProcessor/Deduplicator/Extractor).
#
# Invariant: adapter_result.attributes must never contain a :stage key.
# (It doesn't today, and even if it did, .merge(stage: :scraped) below
# always wins on `create` -- Hash#merge's argument takes precedence.)
class PostLoader
  Result = Struct.new(:outcome, :post, :adapter_result, keyword_init: true) do
    def created?
      outcome == :created
    end

    def refreshed?
      outcome == :refreshed
    end

    def skipped?
      outcome == :skipped
    end

    def no_row?
      outcome == :no_row
    end
  end

  def self.call(adapter_result, ingestion_run_id: nil)
    new.call(adapter_result, ingestion_run_id: ingestion_run_id)
  end

  def call(adapter_result, ingestion_run_id: nil)
    return Result.new(outcome: :no_row, adapter_result: adapter_result) if adapter_result.fatal?

    post = Post.find_by(shortcode: adapter_result.attributes[:shortcode])

    if post.nil?
      post = Post.create!(adapter_result.attributes.merge(stage: :scraped, last_ingestion_run_id: ingestion_run_id))
      return Result.new(outcome: :created, adapter_result: adapter_result, post: post)
    end

    return Result.new(outcome: :skipped, adapter_result: adapter_result, post: post) if post.extracted?

    # raw_payload always overwrites
    # Other Fields only gets overwritten when the new scrape json has a value
    refreshable = adapter_result.attributes.except(:raw_payload).compact
    post.update!(refreshable.merge(raw_payload: adapter_result.attributes[:raw_payload], last_ingestion_run_id: ingestion_run_id))
    Result.new(outcome: :refreshed, adapter_result: adapter_result, post: post)
  end
end
