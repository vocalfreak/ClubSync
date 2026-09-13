require "test_helper"

class Adapters::Apify::PostAdapterTest < ActiveSupport::TestCase
  # Sample posts modeled on Apify's Instagram Post Scraper output.
  SAMPLE_IMAGE_POST = {
    "shortCode" => "DJ9hbKfMxYZ",
    "ownerUsername" => "itsocietymmu",
    "type" => "Image",
    "caption" => "THIS THURSDAY. Riddim night at Memory. Free entry before 11.",
    "url" => "https://www.instagram.com/p/DJ9hbKfMxYZ/",
    "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/463591234_123456789012345_1_n.jpg?se=7&tp=igx",
    "timestamp" => "2026-09-11T12:00:00.000Z",
    "likeCount" => 214,
    "commentsCount" => 8
  }.freeze

  SAMPLE_SIDECAR_POST = {
    "shortCode" => "DJ7xaQpWvBc",
    "ownerUsername" => "clubhyphasia",
    "type" => "Sidecar",
    "caption" => "Feadz closes the week. 2 stages, 6 DJs, one night.\nLink in bio.",
    "url" => "https://www.instagram.com/p/DJ7xaQpWvBc/",
    "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_987654321098765_2_n.jpg?stp=dst-jpg_e35",
    "timestamp" => "2026-09-08T17:30:00.000Z",
    "childPosts" => [
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_1_n.jpg" },
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_2_n.jpg" },
      { "type" => "Image", "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/461234567_3_n.jpg" }
    ],
    "likeCount" => 143,
    "commentsCount" => 12
  }.freeze

  test "maps a valid Image post to a pending result" do
    result = Adapters::Apify::PostAdapter.call(SAMPLE_IMAGE_POST)

    assert result.valid?
    assert_equal [], result.errors
    refute result.fatal

    attrs = result.attributes
    assert_equal "DJ9hbKfMxYZ", attrs[:shortcode]
    assert_equal "itsocietymmu", attrs[:account]
    assert_equal "Image", attrs[:post_type]
    assert_equal SAMPLE_IMAGE_POST["caption"], attrs[:caption]
    assert_equal "https://www.instagram.com/p/DJ9hbKfMxYZ/", attrs[:source_url]
    assert_equal Time.iso8601("2026-09-11T12:00:00.000Z"), attrs[:posted_at]
    assert_equal :pending, attrs[:status]
    assert_equal SAMPLE_IMAGE_POST, attrs[:raw_payload]
  end

  test "source_url is the permalink, not the expiring displayUrl" do
    result = Adapters::Apify::PostAdapter.call(SAMPLE_IMAGE_POST)

    refute_equal SAMPLE_IMAGE_POST["displayUrl"], result.attributes[:source_url]
    assert_match %r{\Ahttps://www\.instagram\.com/p/}, result.attributes[:source_url]
  end

  test "accepts a valid Sidecar post the same as an Image post" do
    result = Adapters::Apify::PostAdapter.call(SAMPLE_SIDECAR_POST)

    assert result.valid?
    assert_equal [], result.errors

    attrs = result.attributes
    assert_equal "Sidecar", attrs[:post_type]
    assert_equal "clubhyphasia", attrs[:account]
    assert_equal "https://www.instagram.com/p/DJ7xaQpWvBc/", attrs[:source_url]
    assert_equal Time.iso8601("2026-09-08T17:30:00.000Z"), attrs[:posted_at]
    assert_equal :pending, attrs[:status]
  end

  test "rejects a Video post but still stores the raw type" do
    post = SAMPLE_IMAGE_POST.merge("type" => "Video")
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.valid?
    refute result.fatal
    assert_equal 1, result.errors.length
    assert_includes result.errors.first, "Video"

    attrs = result.attributes
    assert_equal "Video", attrs[:post_type]
    assert_equal :rejected, attrs[:status]
  end

  test "rejects a post missing ownerUsername with account nil" do
    post = SAMPLE_IMAGE_POST.except("ownerUsername")
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.valid?
    refute result.fatal
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:account]
    assert_equal :rejected, result.attributes[:status]
  end

  test "rejects a post with an unparseable timestamp with posted_at nil" do
    post = SAMPLE_IMAGE_POST.merge("timestamp" => "not a date at all")
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.valid?
    refute result.fatal
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:posted_at]
    assert_equal :rejected, result.attributes[:status]
  end

  test "rejects a post with an absent timestamp with posted_at nil" do
    post = SAMPLE_IMAGE_POST.except("timestamp")
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.valid?
    refute result.fatal
    assert_equal 1, result.errors.length
    assert_nil result.attributes[:posted_at]
    assert_equal :rejected, result.attributes[:status]
  end

  test "accumulates multiple validation errors on one post" do
    post = SAMPLE_IMAGE_POST.except("ownerUsername").merge("timestamp" => "2026-13-99T99:99:00.000Z")
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.valid?
    refute result.fatal
    assert_equal 2, result.errors.length
    assert_nil result.attributes[:account]
    assert_nil result.attributes[:posted_at]
    assert_equal :rejected, result.attributes[:status]
  end

  test "missing shortCode is fatal with nil attributes" do
    post = SAMPLE_IMAGE_POST.except("shortCode")
    result = Adapters::Apify::PostAdapter.call(post)

    assert result.fatal
    assert_nil result.attributes
    refute result.valid?
  end

  test "blank shortCode is fatal" do
    post = SAMPLE_IMAGE_POST.merge("shortCode" => "   ")
    result = Adapters::Apify::PostAdapter.call(post)

    assert result.fatal
    assert_nil result.attributes
  end

  test "never raises on unexpected field types; each becomes a descriptive error" do
    post = SAMPLE_IMAGE_POST.merge("timestamp" => 1_726_789_200, "type" => nil)
    result = Adapters::Apify::PostAdapter.call(post)

    refute result.fatal
    refute result.valid?
    assert_equal 2, result.errors.length
    assert_nil result.attributes[:posted_at]
    assert_includes result.errors.join("\n"), "posted_at"
    assert_includes result.errors.join("\n"), "post_type"
    assert_equal :rejected, result.attributes[:status]
  end

  test "never raises when the whole payload is not a hash" do
    result = Adapters::Apify::PostAdapter.call(nil)

    assert result.fatal
    assert_nil result.attributes
  end

  test "raw_payload equals the full input hash in every case" do
    [
      SAMPLE_IMAGE_POST,
      SAMPLE_SIDECAR_POST,
      SAMPLE_IMAGE_POST.merge("type" => "Video"),
      SAMPLE_IMAGE_POST.except("ownerUsername"),
      SAMPLE_IMAGE_POST.merge("timestamp" => "garbage"),
      SAMPLE_IMAGE_POST.except("ownerUsername").merge("timestamp" => "garbage too")
    ].each do |input|
      result = Adapters::Apify::PostAdapter.call(input)

      refute result.fatal
      assert_equal input, result.attributes[:raw_payload]
      assert result.attributes[:raw_payload].equal?(input)
    end
  end

  test "fatal result leaves the input hash untouched so the caller can still log it" do
    input = SAMPLE_IMAGE_POST.except("shortCode")
    snapshot = Marshal.dump(input)

    result = Adapters::Apify::PostAdapter.call(input)

    assert result.fatal
    assert_nil result.attributes
    assert_equal snapshot, Marshal.dump(input)
  end
end
