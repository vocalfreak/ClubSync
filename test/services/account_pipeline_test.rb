require "test_helper"

class AccountPipelineTest < ActiveSupport::TestCase
  def setup
    @account = create(:account, handle: "testaccount")
    ENV["APIFY_API_TOKEN"] = "apify_api_test_token"
  end

  def teardown
    ENV.delete("APIFY_API_TOKEN")
  end

  def stub_apify_client(posts)
    original = ApifyClient.method(:fetch_account)
    ApifyClient.define_singleton_method(:fetch_account) { |_handle, **_kw| posts }
    yield
  ensure
    ApifyClient.define_singleton_method(:fetch_account, original)
  end

  test "successful account processes posts through the full pipeline" do
    raw_post = build(:apify_image_post)

    stub_apify_client([ raw_post ]) do
      stub_media_processor do
        result = AccountPipeline.call(@account)

        assert result.success?
        assert_equal 1, result.posts_scraped
        assert_equal 1, Post.count
        post = Post.first
        assert_equal raw_post["shortCode"], post.shortcode
        assert post.scraped?, "MediaProcessor is stubbed as skipped, so stage stays scraped"
      end
    end
  end

  test "hands each scraped post to MediaProcessor" do
    posts = Array.new(2) { build(:apify_image_post) }
    calls = []

    stub_apify_client(posts) do
      stub_media_processor(calls) do
        AccountPipeline.call(@account)

        assert_equal 2, calls.length
        assert_equal posts.map { |p| p["shortCode"] }, calls.map { |c| c.first.shortcode }
      end
    end
  end

  test "multiple posts are all processed" do
    posts = Array.new(3) { build(:apify_image_post) }

    stub_apify_client(posts) do
      stub_media_processor do
        result = AccountPipeline.call(@account)

        assert result.success?
        assert_equal 3, result.posts_scraped
        assert_equal 3, Post.count
      end
    end
  end

  test "returns failure result on ApifyClient::TimeoutError" do
    stub_apify_client_error(ApifyClient::TimeoutError, "request timed out") do
      result = AccountPipeline.call(@account)

      refute result.success?
      assert_includes result.errors.first, "request timed out"
      assert_equal 0, result.posts_scraped
    end
  end

  test "returns failure result on ApifyClient::RateLimitedError" do
    stub_apify_client_error(ApifyClient::RateLimitedError, "rate limited") do
      result = AccountPipeline.call(@account)

      refute result.success?
      assert_includes result.errors.first, "rate limited"
    end
  end

  test "returns failure result on Net::OpenTimeout" do
    stub_apify_client_error(Net::OpenTimeout, "connection timed out") do
      result = AccountPipeline.call(@account)

      refute result.success?
      assert_includes result.errors.first, "connection timed out"
    end
  end

  test "propagates unanticipated exceptions (not rescued)" do
    stub_apify_client_error(NoMethodError, "undefined method") do
      assert_raises(NoMethodError) do
        AccountPipeline.call(@account)
      end
    end
  end

  test "forwards ingestion_run_id to PostLoader" do
    run = create(:ingestion_run)
    raw_post = build(:apify_image_post)

    stub_apify_client([ raw_post ]) do
      stub_media_processor do
        AccountPipeline.call(@account, ingestion_run_id: run.id)

        post = Post.last
        assert_equal run.id, post.last_ingestion_run_id
      end
    end
  end

  private

  def stub_media_processor(calls = [])
    original = MediaProcessor.method(:call)
    MediaProcessor.define_singleton_method(:call) do |*args|
      calls << args
      MediaProcessor::Result.new(status: :skipped)
    end
    yield calls
  ensure
    MediaProcessor.define_singleton_method(:call, original)
  end

  def stub_apify_client_error(error_class, message)
    original = ApifyClient.method(:fetch_account)
    ApifyClient.define_singleton_method(:fetch_account) { |_handle, **_kw| raise error_class, message }
    yield
  ensure
    ApifyClient.define_singleton_method(:fetch_account, original)
  end
end
