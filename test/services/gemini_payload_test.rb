require "test_helper"

class GeminiPayloadTest < ActiveSupport::TestCase
  POSTED_AT = Time.zone.parse("2026-09-11T12:00:00Z").freeze

  test "builds contents with the prompt text and inline images in order" do
    images = [
      { bytes: "abc".b, content_type: "image/webp" },
      { bytes: "xyz".b, content_type: "image/webp" }
    ]

    contents = GeminiPayload.build(caption: "Riddim night", posted_at: POSTED_AT, timezone: "Asia/Kuala_Lumpur", images: images)

    assert_equal 1, contents.length
    message = contents.first
    assert_equal "user", message["role"]

    parts = message["parts"]
    assert_includes parts.first["text"], "Riddim night"
    assert_includes parts.first["text"], "2026-09-11"

    assert_equal 3, parts.length
    assert_equal "image/webp", parts[1]["inlineData"]["mimeType"]
    assert_equal Base64.strict_encode64("abc"), parts[1]["inlineData"]["data"]
    assert_equal Base64.strict_encode64("xyz"), parts[2]["inlineData"]["data"]
  end

  test "builds contents with no image parts when none are given" do
    contents = GeminiPayload.build(caption: nil, posted_at: POSTED_AT, timezone: "Asia/Kuala_Lumpur", images: [])

    assert_equal 1, contents.first["parts"].length
    assert_includes contents.first["parts"].first["text"], "Instagram post"
  end
end
