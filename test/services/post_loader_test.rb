require "test_helper"

class PostLoaderTest < ActiveSupport::TestCase
  test "creates a new Post with every mapped attribute, when shortcode is not found" do
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.created?
    post = loader_result.post
    assert_equal apify_post["shortCode"], post.shortcode
    assert_equal apify_post["ownerUsername"], post.account
    assert_equal apify_post["type"], post.post_type
    assert_equal apify_post["caption"], post.caption
    assert_equal apify_post["url"], post.source_url
    assert_equal Time.iso8601(apify_post["timestamp"]), post.posted_at
    assert post.scraped?
    assert_nil post.is_event
    assert_nil post.last_error
  end

  test "skips entirely when the existing post is already deduped" do
    existing = create(:post, :deduped, shortcode: "ABC12345678")
    apify_post = build(:apify_image_post, short_code: "ABC12345678", caption: "totally different caption now")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    loader_result = PostLoader.call(result)

    assert loader_result.skipped?
    existing.reload
    refute_equal "totally different caption now", existing.caption
  end

  test "refreshes an extracted post: extraction output is finished, but dedup (the terminal stage) has not run yet" do
    existing = create(:post, :extracted, shortcode: "ABC12345678", caption: "old caption")
    apify_post = build(:apify_image_post, short_code: "ABC12345678", caption: "updated caption")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    loader_result = PostLoader.call(result)

    assert loader_result.refreshed?
    existing.reload
    assert_equal "updated caption", existing.caption
    assert existing.extracted?, "a refresh does not advance or move a stage"
  end

  test "refreshes every mapped attribute (including raw_payload) when the post exists but isn't extracted yet" do
    existing = create(:post, :media_processed, shortcode: "ABC12345678", caption: "old caption")
    apify_post = build(:apify_image_post, short_code: "ABC12345678", caption: "updated caption")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    loader_result = PostLoader.call(result)

    assert loader_result.refreshed?
    existing.reload
    assert_equal apify_post["ownerUsername"], existing.account
    assert_equal apify_post["type"], existing.post_type
    assert_equal "updated caption", existing.caption
    assert_equal apify_post["url"], existing.source_url
    assert_equal Time.iso8601(apify_post["timestamp"]), existing.posted_at
    assert_equal apify_post, existing.raw_payload
    assert existing.media_processed?, "stage should be untouched by Loader"
  end

  test "a refresh never blanks out a previously-populated field when the new scrape has a nil for it" do
    existing = create(:post, :media_processed, shortcode: "ABC12345678", account: "clubhyphasia")
    apify_post = build(:apify_image_post, :missing_owner, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result)

    existing.reload
    assert_equal "clubhyphasia", existing.account, "a nil in the new scrape should not overwrite existing data"
  end

  test "refreshing a stalled post does not clear last_error or stage_failed_at" do
    existing = create(:post, :media_processed, :stalled, shortcode: "ABC12345678")
    apify_post = build(:apify_image_post, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result)

    existing.reload
    refute_nil existing.last_error
    refute_nil existing.stage_failed_at
  end

  test "creates a row for a structurally-invalid but non-fatal post, stage stays scraped" do
    apify_post = build(:apify_image_post, :unsupported_type)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.created?
    assert_equal "Video", loader_result.post.post_type
    assert loader_result.post.scraped?
  end

  test "does not create a row when the adapter result is fatal" do
    apify_post = build(:apify_image_post, :missing_shortcode)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.no_row?
    assert_nil loader_result.post
    assert_equal 0, Post.count
  end

  test "exposes the adapter result so callers can still access error detail" do
    apify_post = build(:apify_image_post, :missing_owner)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert_equal result, loader_result.adapter_result
    refute_empty loader_result.adapter_result.errors
  end

  test "propagates an unexpected error from Post.create! instead of swallowing it" do
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    original = Post.method(:create!)
    Post.define_singleton_method(:create!) { |*_args| raise ActiveRecord::RecordInvalid.new(Post.new) }
    assert_raises(ActiveRecord::RecordInvalid) do
      PostLoader.call(result)
    end
  ensure
    Post.define_singleton_method(:create!, original)
  end

  test "sets last_ingestion_run_id on create when provided" do
    run = create(:ingestion_run)
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result, ingestion_run_id: run.id)

    assert_equal run.id, loader_result.post.last_ingestion_run_id
  end

  test "sets last_ingestion_run_id on refresh when provided" do
    existing = create(:post, :media_processed, shortcode: "ABC12345678")
    run = create(:ingestion_run)
    apify_post = build(:apify_image_post, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result, ingestion_run_id: run.id)

    existing.reload
    assert_equal run.id, existing.last_ingestion_run_id
  end

  test "does not set last_ingestion_run_id on skip" do
    existing = create(:post, :deduped, shortcode: "ABC12345678", last_ingestion_run_id: nil)
    run = create(:ingestion_run)
    apify_post = build(:apify_image_post, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result, ingestion_run_id: run.id)

    existing.reload
    assert_nil existing.last_ingestion_run_id
  end

  test "does not create a row on no_row so ingestion_run_id is irrelevant" do
    apify_post = build(:apify_image_post, :missing_shortcode)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    run = create(:ingestion_run)

    loader_result = PostLoader.call(result, ingestion_run_id: run.id)

    assert loader_result.no_row?
    assert_equal 0, Post.count
  end

  test "works without ingestion_run_id (backward compatible)" do
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.created?
    assert_nil loader_result.post.last_ingestion_run_id
  end
end
