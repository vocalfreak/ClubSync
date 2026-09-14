require "test_helper"

class Adapters::Apify::PostAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = Adapters::Apify::PostAdapter.new
  end

  test "maps a valid Image post to a valid result" do
    post = build(:apify_image_post)
    result = @adapter.parse_post(post)

    assert result.valid?
    assert_equal [], result.errors
    refute result.fatal?

    attrs = result.attributes
    assert_equal post["shortCode"], attrs[:shortcode]
    assert_equal post["ownerUsername"], attrs[:account]
    assert_equal "Image", attrs[:post_type]
    assert_equal post["caption"], attrs[:caption]
    assert_equal post["url"], attrs[:source_url]
    assert_equal Time.iso8601(post["timestamp"]), attrs[:posted_at]
    assert_equal post, attrs[:raw_payload]
  end

  test "source_url is the permalink, not the expiring displayUrl" do
    post = build(:apify_image_post)
    result = @adapter.parse_post(post)

    refute_equal post["displayUrl"], result.attributes[:source_url]
    assert_match %r{\Ahttps://www\.instagram\.com/p/}, result.attributes[:source_url]
  end

  test "accepts a valid Sidecar post the same as an Image post" do
    post = build(:apify_sidecar_post)
    result = @adapter.parse_post(post)

    assert result.valid?
    assert_equal [], result.errors

    attrs = result.attributes
    assert_equal "Sidecar", attrs[:post_type]
    assert_equal post["ownerUsername"], attrs[:account]
    assert_equal post["url"], attrs[:source_url]
    assert_equal Time.iso8601(post["timestamp"]), attrs[:posted_at]
  end

  test "rejects a Video post but still stores the raw type" do
    post = build(:apify_image_post, :unsupported_type)
    result = @adapter.parse_post(post)

    refute result.valid?
    refute result.fatal?
    assert_equal 1, result.errors.length
    assert_includes result.errors.first, "Video"
    assert_equal "Video", result.attributes[:post_type]
  end

  test "rejects a post missing ownerUsername with account nil" do
    post = build(:apify_image_post, :missing_owner)
    result = @adapter.parse_post(post)

    refute result.valid?
    refute result.fatal?
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:account]
  end

  test "rejects a post with an unparseable timestamp with posted_at nil" do
    post = build(:apify_image_post, :bad_timestamp)
    result = @adapter.parse_post(post)

    refute result.valid?
    refute result.fatal?
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:posted_at]
  end

  test "rejects a post with an absent timestamp with posted_at nil" do
    post = build(:apify_image_post, :missing_timestamp)
    result = @adapter.parse_post(post)

    refute result.valid?
    refute result.fatal?
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:posted_at]
  end

  test "accumulates multiple validation errors on one post" do
    post = build(:apify_image_post, :missing_owner, timestamp: "2026-13-99T99:99:00.000Z")
    result = @adapter.parse_post(post)

    refute result.valid?
    refute result.fatal?
    assert_equal 2, result.errors.length
    assert_nil result.attributes[:account]
    assert_nil result.attributes[:posted_at]
  end

  test "missing shortCode is fatal with nil attributes" do
    post = build(:apify_image_post, :missing_shortcode)
    result = @adapter.parse_post(post)

    assert result.fatal?
    assert_nil result.attributes
    refute result.valid?
  end

  test "blank shortCode is fatal" do
    post = build(:apify_image_post, :blank_shortcode)
    result = @adapter.parse_post(post)

    assert result.fatal?
    assert_nil result.attributes
  end

  test "never raises on unexpected field types; each becomes a descriptive error" do
    post = build(:apify_image_post, timestamp: 1_726_789_200, type: nil)
    result = @adapter.parse_post(post)

    refute result.fatal?
    refute result.valid?
    assert_equal 2, result.errors.length
    assert_nil result.attributes[:posted_at]
    assert_includes result.errors.join("\n"), "posted_at"
    assert_includes result.errors.join("\n"), "post_type"
  end

  test "never raises when the whole payload is not a hash" do
    result = @adapter.parse_post(nil)

    assert result.fatal?
    assert_nil result.attributes
  end

  test "raw_payload equals the full input hash in every case" do
    [
      build(:apify_image_post),
      build(:apify_sidecar_post),
      build(:apify_image_post, :unsupported_type),
      build(:apify_image_post, :missing_owner),
      build(:apify_image_post, timestamp: "garbage"),
      build(:apify_image_post, :missing_owner, timestamp: "garbage too")
    ].each do |input|
      result = @adapter.parse_post(input)

      refute result.fatal?
      assert_equal input, result.attributes[:raw_payload]
      assert result.attributes[:raw_payload].equal?(input)
    end
  end

  test "fatal result leaves the input hash untouched so the caller can still log it" do
    post = build(:apify_image_post, :missing_shortcode)
    snapshot = Marshal.dump(post)

    result = @adapter.parse_post(post)

    assert result.fatal?
    assert_nil result.attributes
    assert_equal snapshot, Marshal.dump(post)
  end
end
