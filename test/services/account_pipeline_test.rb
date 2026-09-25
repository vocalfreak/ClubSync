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
        assert_equal({}, result.stage_results, "skipped media outcomes are not tallied")
        assert_equal 0, result.unexpected_errors
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

  test "regression: a stalled media_processed post skips media and is extracted" do
    existing = create(:post, :media_processed)
    raw_post = build(:apify_image_post, short_code: existing.shortcode)
    media_calls = []
    extract_calls = []

    stub_apify_client([ raw_post ]) do
      stub_media_processor(media_calls) do
        stub_extractor_with(->(_post) { Extractor::Result.new(status: :success) }, extract_calls) do
          result = AccountPipeline.call(@account)

          assert result.success?
          assert_empty media_calls, "media must not re-run for an already-media_processed post"
          assert_equal [ existing ], extract_calls.map(&:first), "the stalled post is handed to the extractor"
          assert_equal({ "extracted" => { "succeeded" => 1 } }, result.stage_results)
        end
      end
    end
  end

  test "records a whole-service extraction failure onto the outage tracker" do
    existing = create(:post, :media_processed)
    raw_post = build(:apify_image_post, short_code: existing.shortcode)
    outage = GeminiOutage.new

    stub_apify_client([ raw_post ]) do
      stub_media_processor do
        stub_extractor_with(->(_post) { Extractor::Result.new(status: :failed, error_kind: :whole_service, error: "quota") }) do
          result = AccountPipeline.call(@account, outage: outage)

          assert result.success?
          assert_equal 1, outage.consecutive_failures
          refute outage.active?
          assert_equal({ "extracted" => { "failed" => 1 } }, result.stage_results)
        end
      end
    end
  end

  test "activates the outage at 5: the 5th whole-service failure skips extraction for the rest of the run" do
    posts = Array.new(6) { build(:apify_image_post) }
    outage = GeminiOutage.new
    extract_calls = []

    stub_apify_client(posts) do
      stub_media_processor_with(->(post) { post.media_processed!; MediaProcessor::Result.new(status: :success) }) do
        stub_extractor_with(->(_post) { Extractor::Result.new(status: :failed, error_kind: :whole_service, error: "quota") }, extract_calls) do
          result = AccountPipeline.call(@account, outage: outage)

          assert result.success?
          assert outage.active?, "five consecutive whole-service failures activate the outage"
          assert_equal 5, extract_calls.length, "the 6th post's extraction is skipped once active"
          assert_equal(
            { "media_processed" => { "succeeded" => 6 }, "extracted" => { "failed" => 5 } },
            result.stage_results
          )
          refute_includes extract_calls.map(&:first), Post.find_by(shortcode: posts.last["shortCode"]),
            "the post behind the active outage is never handed to the extractor"
        end
      end
    end
  end

  test "skips extraction entirely while the outage is already active" do
    existing = create(:post, :media_processed)
    raw_post = build(:apify_image_post, short_code: existing.shortcode)
    outage = GeminiOutage.new
    5.times { outage.record(Extractor::Result.new(status: :failed, error_kind: :whole_service, error: "boom")) }
    assert outage.active?
    extract_calls = []

    stub_apify_client([ raw_post ]) do
      stub_media_processor do
        stub_extractor_with(->(_post) { raise "extractor must not run while active" }, extract_calls) do
          result = AccountPipeline.call(@account, outage: outage)

          assert result.success?
          assert_empty extract_calls
          assert existing.reload.media_processed?, "posts wait at media_processed while the outage is active"
          assert_equal({}, result.stage_results)
        end
      end
    end
  end

  test "an unexpected error on one post does not stop the others and is recorded on the post" do
    posts = Array.new(2) { build(:apify_image_post) }
    media_calls = []
    raise_on_first = true

    original = MediaProcessor.method(:call)
    MediaProcessor.define_singleton_method(:call) do |*args|
      media_calls << args
      if raise_on_first
        raise_on_first = false
        raise NoMethodError, "boom on the first post"
      end
      MediaProcessor::Result.new(status: :success)
    end

    begin
      result = nil
      stub_apify_client(posts) do
        result = AccountPipeline.call(@account)
      end
    ensure
      MediaProcessor.define_singleton_method(:call, original)
    end

    assert result.success?, "one bad post must not fail the whole account"
    assert_equal 2, media_calls.length
    assert_equal 1, result.unexpected_errors
    assert_equal({ "media_processed" => { "succeeded" => 1 } }, result.stage_results)

    failed_post = media_calls.first.first.reload
    assert_match(/^Unexpected NoMethodError: boom on the first post/, failed_post.last_error)
    refute_nil failed_post.stage_failed_at
    assert failed_post.scraped?, "the raised post never advanced its stage"
  end

  test "tallies media succeeded and failed outcomes into stage_results" do
    posts = Array.new(2) { build(:apify_image_post) }

    stub_apify_client(posts) do
      stub_media_processor_with(->(_post) { MediaProcessor::Result.new(status: :success) }) do
        result = AccountPipeline.call(@account)
        assert_equal({ "media_processed" => { "succeeded" => 2 } }, result.stage_results)
        assert_equal 0, result.unexpected_errors
      end
    end

    stub_apify_client(posts) do
      stub_media_processor_with(->(_post) { MediaProcessor::Result.new(status: :failed, error: "nope") }) do
        result = AccountPipeline.call(@account)
        assert_equal({ "media_processed" => { "failed" => 2 } }, result.stage_results)
      end
    end
  end

  test "a dead-lettered post is tallied and never touches Gemini" do
    existing = create(:post, :media_processed)
    3.times { create(:extraction, :failed, post: existing, error_kind: "this_post") }
    raw_post = build(:apify_image_post, short_code: existing.shortcode)
    gemini_calls = 0
    original = GeminiClient.method(:extract)
    GeminiClient.define_singleton_method(:extract) { |**_kwargs| gemini_calls += 1 }

    begin
      stub_apify_client([ raw_post ]) do
        stub_media_processor do
          result = AccountPipeline.call(@account)

          assert result.success?
          assert_equal({ "extracted" => { "dead_lettered" => 1 } }, result.stage_results)
          assert_equal 0, gemini_calls, "the dead-letter guard returns before any Gemini call"
          assert existing.reload.media_processed?
        end
      end
    ensure
      GeminiClient.define_singleton_method(:extract, original)
    end
  end

  private

  def stub_media_processor_with(result_builder, calls = [])
    original = MediaProcessor.method(:call)
    MediaProcessor.define_singleton_method(:call) do |*args|
      calls << args
      result_builder.call(args.first)
    end
    yield calls
  ensure
    MediaProcessor.define_singleton_method(:call, original)
  end

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

  def stub_extractor_with(result_builder, calls = [])
    original = Extractor.method(:call)
    Extractor.define_singleton_method(:call) do |post, **kwargs|
      calls << [ post, kwargs ]
      result_builder.call(post)
    end
    yield calls
  ensure
    Extractor.define_singleton_method(:call, original)
  end

  def stub_apify_client_error(error_class, message)
    original = ApifyClient.method(:fetch_account)
    ApifyClient.define_singleton_method(:fetch_account) { |_handle, **_kw| raise error_class, message }
    yield
  ensure
    ApifyClient.define_singleton_method(:fetch_account, original)
  end
end
