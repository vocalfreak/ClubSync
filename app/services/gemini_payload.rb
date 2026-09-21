require "base64"

# Builds the `contents` for GeminiClient from a post's caption, posted_at,
# timezone and images (bytes + content type, in `position` order). The one
# place base64 inline image encoding happens. Pure — no DB, no network.
class GeminiPayload
  def self.build(caption:, posted_at:, timezone:, images: [])
    parts = [ { "text" => ExtractionPrompt.user_text(caption: caption, posted_at: posted_at, timezone: timezone) } ]

    Array(images).each do |image|
      parts << {
        "inlineData" => {
          "mimeType" => image[:content_type],
          "data" => Base64.strict_encode64(image[:bytes])
        }
      }
    end

    [ { "role" => "user", "parts" => parts } ]
  end
end
