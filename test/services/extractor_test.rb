require "test_helper"

class ExtractorTest < ActiveSupport::TestCase
  # Real decodable image bytes: the decode preflight rejects non-image
  # buffers, so fake stores must serve real ones. Lazy so libvips doesn't
  # initialize worker threads in the parent before minitest forks.
  def self.valid_img
    @valid_img ||= Vips::Image.black(1, 1).write_to_buffer(".png").freeze
  end

  class FakeClient
    attr_reader :calls

    def initialize(payload: nil, error: nil, failures: 0)
      @payload = payload
      @error = error
      @failures = failures
      @calls = []
    end

    def extract(**kwargs)
      @calls << kwargs
      raise @error if @error

      if @failures.positive?
        @failures -= 1
        raise GeminiClient::RateLimitedError, "quota exceeded"
      end

      raise "FakeClient needs a payload for a success" if @payload.nil?

      GeminiClient::Response.new(
        text: @payload.to_json,
        parsed: @payload,
        prompt_tokens: 412,
        candidates_tokens: 61,
        duration_ms: 1200,
        model: "gemini-3.8-flash"
      )
    end
  end

  class FakeObjectStore
    attr_reader :reads

    def initialize(bytes_by_key = {})
      @bytes_by_key = bytes_by_key
      @reads = []
    end

    def get(key)
      @reads << key
      @bytes_by_key[key] || ExtractorTest.valid_img
    end
  end

  POSTED_AT = Time.zone.parse("2026-04-20T12:00:00Z").freeze

  def post_with_images(keys, **overrides)
    post = create(:post, :media_processed, posted_at: POSTED_AT, **overrides)
    keys.each_with_index do |key, position|
      Image.create!(
        post: post,
        position: position,
        b2_key: key,
        content_type: "image/webp",
        width: 100,
        height: 100,
        byte_size: 4
      )
    end
    post
  end

  test "is skipped when the post is not at media_processed" do
    post = create(:post) # scraped
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.skipped?
    assert_empty client.calls
    assert_equal 0, Extraction.count
    assert_equal 0, Event.count
  end

  test "is skipped for an already-extracted post" do
    post = create(:post, :extracted)
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.skipped?
    assert_empty client.calls
  end

  test "success for an event post creates extraction + event rows and advances the post" do
    post = post_with_images(%w[b2-1])
    payload = build(:gemini_payload).merge(
      "venue" => "Rumah Amanah, Hulu Langat",
      "starts_date" => "2026-05-02",
      "starts_time" => "07:30",
      "ends_date" => "2026-05-02",
      "ends_time" => "14:00",
      "members_only" => true,
      "registration_via" => "qr",
      "confidence" => { "title" => 0.8, "starts_at" => 0.9, "venue" => 0.8 }
    )

    result = Extractor.call(post, client: FakeClient.new(payload: payload), object_store: FakeObjectStore.new)

    assert result.success?
    refute result.failed?
    assert post.reload.extracted?
    assert_equal "event", post.category
    assert_equal true, post.is_event
    assert_nil post.last_error
    assert_nil post.stage_failed_at

    extraction = Extraction.last
    assert_equal "succeeded", extraction.status
    assert_equal "v3", extraction.prompt_version
    assert_equal "event", extraction.category
    assert_equal payload, extraction[:raw_response]
    assert_equal 1, extraction.image_count
    assert_equal 412, extraction.input_tokens
    assert_equal 61, extraction.output_tokens
    assert_equal "gemini-3.8-flash", extraction.model

    event = Event.last
    assert_equal post.id, event.post_id
    assert_equal "Rumah Amanah, Hulu Langat", event.venue
    assert_equal Date.new(2026, 5, 2), event.starts_on
    assert_equal "07:30", event.starts_time.strftime("%H:%M")
    assert_equal Date.new(2026, 5, 2), event.ends_on
    assert_equal "14:00", event.ends_time.strftime("%H:%M")
    assert_equal true, event.details["members_only"]
    assert_equal "qr", event.details["registration_via"]
    assert_equal 0.8, event.title_confidence
    assert_equal 0.9, event.starts_at_confidence
    assert_equal 0.8, event.venue_confidence
  end

  test "success for a non-event post stores no events row and marks is_event false" do
    post = post_with_images(%w[b2-1])

    result = Extractor.call(
      post,
      client: FakeClient.new(payload: build(:gemini_payload, :fundraising)),
      object_store: FakeObjectStore.new
    )

    assert result.success?
    assert post.reload.extracted?
    assert_equal "fundraising", post.category
    assert_equal false, post.is_event
    assert_equal 0, Event.count
    assert_equal 1, Extraction.count
    assert_equal "succeeded", Extraction.last.status
  end

  test "a csrw-caption post is force-corrected to the csrw category with no event row (guard, not a Gemini verdict)" do
    post = post_with_images(%w[b2-1], caption: "Come find our booth during CSRW!")
    payload = build(:gemini_payload) # category "event", full event fields

    result = Extractor.call(post, client: FakeClient.new(payload: payload), object_store: FakeObjectStore.new)

    assert result.success?
    post.reload
    assert post.extracted?
    assert_equal Categories::CSRW, post.category
    refute post.is_event?
    assert_equal 0, Event.count, "no event row is ever created for a csrw post"

    extraction = Extraction.last
    assert_equal "succeeded", extraction.status
    assert_equal Categories::CSRW, extraction.category, "the stored category is the guarded value"
    assert_equal "event", extraction[:raw_response]["category"], "Gemini's unfiltered answer is preserved"
  end

  test "a passing 'after CSRW' mention still wins the guard — recall over precision" do
    post = post_with_images(%w[b2-1], caption: "Drop by our booth again after CSRW!")
    payload = build(:gemini_payload)

    result = Extractor.call(post, client: FakeClient.new(payload: payload), object_store: FakeObjectStore.new)

    assert result.success?
    assert_equal Categories::CSRW, post.reload.category, "marker match wins even for an incidental mention"
    refute post.reload.is_event?
    assert_equal 0, Event.count
  end

  test "a plain event caption is never touched by the guard" do
    post = post_with_images(%w[b2-1], caption: "Gallery opening downtown at 6pm")
    payload = build(:gemini_payload).merge("venue" => "Rumah Amanah, Hulu Langat")

    result = Extractor.call(post, client: FakeClient.new(payload: payload), object_store: FakeObjectStore.new)

    assert result.success?
    assert_equal "event", post.reload.category
    assert post.reload.is_event?
    assert_equal 1, Event.count, "a non-csrw post keeps its event row"
  end

  test "thresholds a placeholder venue before persisting" do
    post = post_with_images(%w[b2-1])
    payload = build(:gemini_payload).merge(
      "venue" => "TBA",
      "confidence" => { "title" => 0.8, "starts_at" => 0.8, "venue" => 0.8 }
    )

    Extractor.call(post, client: FakeClient.new(payload: payload), object_store: FakeObjectStore.new)

    assert_equal true, post.reload.extracted?
    assert_nil Event.last.venue
    assert_equal 0.0, Event.last.venue_confidence
  end

  test "a whole-service Gemini failure returns failed, keeps the stage and records the failure" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(error: GeminiClient::RateLimitedError.new("quota exceeded"))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new, sleeper: ->(_seconds) { })

    assert result.failed?
    assert_equal :whole_service, result.error_kind
    assert_equal 3, client.calls.length, "all three retry attempts are exhausted before failing"
    assert post.reload.media_processed?, "stage stays media_processed for the next run"
    assert_equal "GeminiClient::RateLimitedError: quota exceeded", post.last_error
    refute_nil post.stage_failed_at
    assert_equal 0, Event.count

    extraction = Extraction.last
    assert_equal "failed", extraction.status
    assert_equal "whole_service", extraction.error_kind
    assert_match(/quota exceeded/, extraction.error)
  end

  test "a blocked response fails this-post" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(error: GeminiClient::BlockedError.new("safety"))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert post.reload.media_processed?
    assert_equal "this_post", Extraction.last.error_kind
  end

  test "an invalid Gemini payload fails this-post as an InvalidResponseError" do
    post = post_with_images(%w[b2-1])

    result = Extractor.call(
      post,
      client: FakeClient.new(payload: build(:gemini_payload, :bad_category)),
      object_store: FakeObjectStore.new
    )

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert_match(/InvalidResponseError: invalid Gemini response/, post.reload.last_error)
    assert post.reload.media_processed?
  end

  test "an image read failure from B2 fails this-post" do
    post = post_with_images(%w[b2-1])
    store = FakeObjectStore.new
    store.define_singleton_method(:get) { |_key| raise Aws::S3::Errors::ServiceError.new("ctx", "gone") }

    result = Extractor.call(post, client: FakeClient.new(payload: build(:gemini_payload)), object_store: store)

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert_match(/Aws::S3::Errors::ServiceError/, post.reload.last_error)
  end

  test "a media_processed post with no images fails this-post without calling Gemini" do
    post = create(:post, :media_processed)
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert_empty client.calls
    assert_match(/no images/, post.reload.last_error)
    assert_equal "failed", Extraction.last.status
    assert_equal "this_post", Extraction.last.error_kind
  end

  test "success writes are atomic: an events failure rolls the transaction back" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(payload: build(:gemini_payload))
    store = FakeObjectStore.new

    original = Event.method(:create!)
    Event.define_singleton_method(:create!) { |*| raise "boom" }
    begin
      assert_raises(RuntimeError) { Extractor.call(post, client: client, object_store: store) }
    ensure
      Event.define_singleton_method(:create!, original)
    end

    assert post.reload.media_processed?
    assert_nil post.category
    assert_nil post.is_event
    assert_equal 0, Extraction.count
    assert_equal 0, Event.count
  end

  test "reads images in position order through ObjectStore#get" do
    keys = %w[b2-0 b2-1 b2-2]
    bytes = {
      "b2-0" => Vips::Image.black(1, 1).write_to_buffer(".png").b,
      "b2-1" => Vips::Image.black(2, 1).write_to_buffer(".png").b,
      "b2-2" => Vips::Image.black(1, 2).write_to_buffer(".png").b
    }
    store = FakeObjectStore.new(bytes)
    client = FakeClient.new(payload: build(:gemini_payload))
    post = post_with_images(keys)
    Extractor.call(post, client: client, object_store: store)

    assert_equal keys, store.reads, "B2 reads happen in position order"
    parts = client.calls.first[:contents].first["parts"]
    assert_equal(
      %w[b2-0 b2-1 b2-2].map { |key| Base64.strict_encode64(bytes[key]) },
      parts.drop(1).map { |part| part["inlineData"]["data"] },
      "inline images keep position order in the payload"
    )
  end

  test "the Gemini call carries the current prompt version's system instruction and config" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(payload: build(:gemini_payload))

    Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    kwargs = client.calls.first
    assert_equal ExtractionPrompt.system_instruction, kwargs[:system_instruction]
    assert_equal ExtractionPrompt.generation_config, kwargs[:generation_config]
    assert_equal "user", kwargs[:contents].first["role"]
  end

  test "retries transient failures: two failures then a success is three calls total and :success" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(payload: build(:gemini_payload), failures: 2)

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new, sleeper: ->(_seconds) { })

    assert result.success?
    assert_equal 3, client.calls.length, "each transient failure is retried up to three attempts"
    assert post.reload.extracted?
  end

  test "AuthError is not retried: one call, one whole-service failure" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(error: GeminiClient::AuthError.new("bad key"))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new, sleeper: ->(_seconds) { })

    assert result.failed?
    assert_equal :whole_service, result.error_kind
    assert_equal 1, client.calls.length, "a config problem fails once rather than adding latency"
  end

  test "a dead-lettered post is skipped without a Gemini call and without a new extraction row" do
    post = post_with_images(%w[b2-1])
    3.times { create(:extraction, :failed, post: post, error_kind: "this_post") }
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.skipped?
    assert result.dead_lettered?
    assert_empty client.calls
    assert_equal 3, Extraction.count, "the dead-letter guard writes no new row"
    assert post.reload.media_processed?
  end

  test "a whole_service row in the tail prevents dead-lettering" do
    post = post_with_images(%w[b2-1])
    create(:extraction, :failed, post: post, error_kind: "this_post")
    create(:extraction, :failed, post: post, error_kind: "whole_service")
    create(:extraction, :failed, post: post, error_kind: "this_post")
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    refute result.dead_lettered?
    assert_equal 1, client.calls.length, "a Gemini-wide outage in the tail means the service may answer now"
    assert result.success?
  end

  test "a succeeded row resets the dead-letter streak" do
    post = post_with_images(%w[b2-1])
    2.times { create(:extraction, :failed, post: post, error_kind: "this_post") }
    create(:extraction, post: post)
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    refute result.dead_lettered?
    assert result.success?
  end

  test "fewer than three extraction rows is never dead-lettered" do
    post = post_with_images(%w[b2-1])
    2.times { create(:extraction, :failed, post: post, error_kind: "this_post") }

    refute post.dead_lettered?
    assert_empty Post.dead_lettered
  end

  test "Post.dead_lettered scope finds only three-in-a-row this_post failures" do
    dead = post_with_images(%w[b2-1])
    3.times { create(:extraction, :failed, post: dead, error_kind: "this_post") }

    clean = post_with_images(%w[b2-2])
    3.times { create(:extraction, :failed, post: clean, error_kind: "this_post") }
    create(:extraction, post: clean, status: "succeeded")

    assert_equal [ dead.id ], Post.dead_lettered.pluck(:id)
  end

  test "undecodable image bytes fail this-post before any Gemini call" do
    post = post_with_images(%w[b2-1])
    store = FakeObjectStore.new("b2-1" => "garbage, not an image")
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: store, sleeper: ->(_seconds) { })

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert_empty client.calls, "no round-trip is spent on a corrupt B2 read"
    assert_match(/UndecodableImageError/, post.reload.last_error)
  end

  test "a payload over the hard limit fails this-post" do
    post = post_with_images(%w[b2-1])
    client = FakeClient.new(error: GeminiClient::PayloadTooLargeError.new("too big"))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new)

    assert result.failed?
    assert_equal :this_post, result.error_kind
    assert_equal 1, client.calls.length
  end

  test "threads ingestion_run_id into both succeeded and failed extraction rows" do
    run = create(:ingestion_run)
    post = post_with_images(%w[b2-1])

    success = Extractor.call(post, client: FakeClient.new(payload: build(:gemini_payload)),
                                    object_store: FakeObjectStore.new, ingestion_run_id: run.id)
    assert success.success?
    assert_equal run.id, Extraction.last.ingestion_run_id

    post2 = post_with_images(%w[b2-2])
    failure = Extractor.call(post2, client: FakeClient.new(error: GeminiClient::BlockedError.new("safety")),
                                    object_store: FakeObjectStore.new, ingestion_run_id: run.id)
    assert failure.failed?
    assert_equal run.id, Extraction.last.ingestion_run_id
  end

  test "a dead-lettered post skips even when an explicit model is given (rotates off the single-model pool)" do
    post = post_with_images(%w[b2-1])
    3.times { create(:extraction, :failed, post: post, error_kind: "this_post") }
    client = FakeClient.new(payload: build(:gemini_payload))

    result = Extractor.call(post, client: client, object_store: FakeObjectStore.new, model: "gemini-2.5-flash")

    assert result.skipped?
    assert result.dead_lettered?
    assert_empty client.calls
  end
end
