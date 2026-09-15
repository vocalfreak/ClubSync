require "test_helper"

class MediaProcessorTest < ActiveSupport::TestCase
  SAMPLE_IMAGE_POST = {
    "shortCode" => "DJ9hbKfMxYZ",
    "ownerUsername" => "itsocietymmu",
    "type" => "Image",
    "caption" => "THIS THURSDAY. Riddim night at Memory. Free entry before 11.",
    "url" => "https://www.instagram.com/p/DJ9hbKfMxYZ/",
    "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/463591234_1_n.jpg?se=7&tp=igx",
    "timestamp" => "2026-09-11T12:00:00.000Z",
    "likeCount" => 214
  }.freeze

  SAMPLE_SIDECAR_POST = {
    "shortCode" => "DJ7xaQpWvBc",
    "ownerUsername" => "clubhyphasia",
    "type" => "Sidecar",
    "caption" => "Feadz closes the week. 2 stages, 6 DJs, one night.\nLink in bio.",
    "url" => "https://www.instagram.com/p/DJ7xaQpWvBc/",
    "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_0_n.jpg",
    "timestamp" => "2026-09-08T17:30:00.000Z",
    "childPosts" => [
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_1_n.jpg" },
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_2_n.jpg" },
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_3_n.jpg" }
    ],
    "likeCount" => 143
  }.freeze

  class FakeObjectStore
    attr_reader :calls

    def initialize
      @calls = []
    end

    def put(bytes, content_type:)
      @calls << { bytes: bytes, content_type: content_type }
      "b2-key-#{@calls.length}"
    end
  end

  def setup
    @image_bytes = File.binread(Rails.root.join("test.jpg"))
  end

  def build_post(raw_payload, stage: :scraped, **overrides)
    Post.create!(
      shortcode: raw_payload["shortCode"],
      account: raw_payload["ownerUsername"],
      post_type: raw_payload["type"],
      caption: raw_payload["caption"],
      source_url: raw_payload["url"],
      posted_at: Time.iso8601(raw_payload["timestamp"]),
      raw_payload: raw_payload,
      stage: stage,
      **overrides
    )
  end

  def process(post, object_store: FakeObjectStore.new, raw_payload: post.raw_payload, &fetcher)
    fetcher ||= ->(_url) { @image_bytes }
    MediaProcessor.call(post, object_store: object_store, raw_payload: raw_payload, fetcher: fetcher)
  end

  def wide_image_bytes
    Vips::Image.black(2000, 1200).colourspace(:srgb).write_to_buffer(".jpg")
  end

  test "processes a single image on an Image post and persists it at position 0" do
    post = build_post(SAMPLE_IMAGE_POST)
    object_store = FakeObjectStore.new

    result = process(post, object_store: object_store)

    assert result.success?
    assert post.media_processed?, "stage should advance to media_processed on success"
    assert_equal 1, post.images.count

    image = post.images.first
    assert_equal 0, image.position
    assert_equal "b2-key-1", image.b2_key
    assert_equal "image/webp", image.content_type
    assert_equal 1080, image.width
    assert_equal 1350, image.height
    assert_equal object_store.calls.first[:bytes].bytesize, image.byte_size
    assert_nil image.dhash
  end

  test "processes Sidecar images in childPosts order with 0-indexed positions" do
    post = build_post(SAMPLE_SIDECAR_POST)
    fetched_urls = []
    object_store = FakeObjectStore.new

    result = process(post, object_store: object_store) do |url|
      fetched_urls << url
      @image_bytes
    end

    assert result.success?
    expected_urls = SAMPLE_SIDECAR_POST["childPosts"].map { |child| child["displayUrl"] }
    assert_equal expected_urls, fetched_urls
    assert_equal %w[0 1 2], post.images.map(&:position).map(&:to_s)
    assert_equal [ "b2-key-1", "b2-key-2", "b2-key-3" ], post.images.map(&:b2_key)
    assert_equal 3, object_store.calls.length
  end

  test "passes content_type image/webp on every object store call, never the default" do
    post = build_post(SAMPLE_IMAGE_POST)
    object_store = FakeObjectStore.new

    process(post, object_store: object_store)

    assert_equal 1, object_store.calls.length
    refute_nil object_store.calls.first[:content_type]
    assert_equal "image/webp", object_store.calls.first[:content_type]
  end

  test "rolls back every images row and marks the post failed when any image fails" do
    post = build_post(SAMPLE_SIDECAR_POST)
    fresh_payload = SAMPLE_SIDECAR_POST.merge(
      "childPosts" => SAMPLE_SIDECAR_POST["childPosts"].map.with_index do |child, i|
        child.merge("displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_#{i}_fresh.jpg")
      end
    )
    object_store = FakeObjectStore.new
    calls = 0

    result = process(post, object_store: object_store, raw_payload: fresh_payload) do |_url|
      calls += 1
      raise "midway failure" if calls == 2

      @image_bytes
    end

    assert result.failed?
    refute_nil result.error
    assert_equal 0, post.images.count
    assert post.scraped?, "stage should stay put on failure"
    refute_nil post.last_error
    refute_nil post.stage_failed_at
    assert_equal fresh_payload, post.raw_payload
  end

  test "re-running against a failed post with a fresh payload succeeds and flip stage to media_processed, clearing error state" do
    stale_payload = SAMPLE_IMAGE_POST.merge(
      "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/expired_url.jpg"
    )
    post = build_post(stale_payload, last_error: "connection reset", stage_failed_at: 1.hour.ago)
    fresh_payload = SAMPLE_IMAGE_POST.merge(
      "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/463591234_fresh.jpg"
    )

    result = process(post, raw_payload: fresh_payload)

    assert result.success?
    assert post.media_processed?, "stage should advance to media_processed on success"
    assert_nil post.last_error
    assert_nil post.stage_failed_at
    assert_equal fresh_payload, post.raw_payload
    assert_equal 1, post.images.count
    assert_equal "b2-key-1", post.images.first.b2_key
    refute_equal stale_payload, post.raw_payload
  end

  test "image posts over 1080px wide are resized to a max width of 1080 preserving aspect ratio" do
    post = build_post(SAMPLE_IMAGE_POST)

    result = process(post) { wide_image_bytes }

    assert result.success?
    image = post.images.first
    assert_equal 1080, image.width
    assert_equal 648, image.height
  end

  [ "media_processed", "deduped", "extracted" ].each do |stage|
    test "is a no-op for a #{stage} post: no fetch, no upload, no db write" do
      original_payload = SAMPLE_IMAGE_POST
      post = build_post(original_payload, stage: stage)
      fresh_payload = SAMPLE_IMAGE_POST.merge(
        "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/463591234_fresh.jpg"
      )
      object_store = FakeObjectStore.new
      fetched = 0

      result = process(post, object_store: object_store, raw_payload: fresh_payload) do |_url|
        fetched += 1
        @image_bytes
      end

      assert result.skipped?
      assert_equal 0, fetched
      assert_equal 0, object_store.calls.length
      assert_equal 0, post.images.count
      assert_equal stage, post.stage
      assert_equal original_payload, post.raw_payload
    end
  end
end
