require "net/http"
require "uri"
require "openssl"
require "socket"
require "timeout"
require "vips"

class MediaProcessor
  class MediaProcessingError < StandardError; end

  Result = Struct.new(:status, :error, keyword_init: true) do
    def success?
      status == :success
    end

    def skipped?
      status == :skipped
    end

    def failed?
      status == :failed
    end
  end

  MAX_WIDTH = 1080
  CONTENT_TYPE = "image/webp".freeze
  REDIRECT_LIMIT = 3

  def self.call(post, **kwargs)
    new(post, **kwargs).call
  end

  def initialize(post, raw_payload: nil, object_store: ObjectStore.new, fetcher: nil)
    @post = post
    @raw_payload = raw_payload || post.raw_payload
    @object_store = object_store
    @fetcher = fetcher || default_fetcher
  end

  def call
    return Result.new(status: :skipped) if skipped?

    image_urls = build_image_urls
    return fail!(MediaProcessingError.new("no displayUrl found in raw_payload")) if image_urls.empty?

    Post.transaction do
      @post.images.destroy_all
      image_urls.each_with_index do |url, position|
        process_and_persist_image(url, position)
      end
      @post.raw_payload = @raw_payload
      @post.stage = :media_processed
      @post.last_error = nil
      @post.stage_failed_at = nil
      @post.save!
    end

    @post.images.reset
    Result.new(status: :success)
  rescue StandardError => e
    fail!(e)
  end

  private

  def skipped?
    !@post.scraped?
  end

  def build_image_urls
    case @raw_payload["type"]
    when "Image"
      [ @raw_payload["displayUrl"] ].compact
    when "Sidecar"
      Array(@raw_payload["childPosts"]).map { |child| child["displayUrl"] }.compact
    else
      []
    end
  end

  def process_and_persist_image(url, position)
    bytes = @fetcher.call(url)
    raise MediaProcessingError, "empty response fetching #{url}" if bytes.nil? || bytes.empty?

    processed = resize_and_encode(bytes)
    key = @object_store.put(processed[:bytes], content_type: CONTENT_TYPE)

    Image.create!(
      post_id: @post.id,
      position: position,
      b2_key: key,
      content_type: CONTENT_TYPE,
      width: processed[:width],
      height: processed[:height],
      byte_size: processed[:bytes].bytesize
    )
  end

  def resize_and_encode(bytes)
    image = Vips::Image.new_from_buffer(bytes, "", access: :sequential)
    image = image.resize(MAX_WIDTH.to_f / image.width) if image.width > MAX_WIDTH
    { width: image.width, height: image.height, bytes: image.write_to_buffer(".webp") }
  end

  def fail!(error)
    @post.images.reset
    @post.update(last_error: error.message, stage_failed_at: Time.current, raw_payload: @raw_payload)
    Result.new(status: :failed, error: error)
  rescue StandardError
    Result.new(status: :failed, error: error)
  end

  def default_fetcher
    ->(url) { fetch(url) }
  end

  def fetch(url, redirect_limit: REDIRECT_LIMIT)
    uri = URI.parse(url.to_s)
    raise MediaProcessingError, "#{url.inspect} is not an http(s) URL" unless uri.is_a?(URI::HTTP)

    response = Net::HTTP.get_response(uri)

    if response.is_a?(Net::HTTPRedirection) && response["location"]
      raise MediaProcessingError, "too many redirects fetching #{url}" if redirect_limit <= 0

      return fetch(URI.join(url, response["location"]).to_s, redirect_limit: redirect_limit - 1)
    end

    raise MediaProcessingError, "HTTP #{response.code} fetching #{url}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue URI::InvalidURIError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT => e
    raise MediaProcessingError, "fetch failed for #{url}: #{e.message}"
  end
end
