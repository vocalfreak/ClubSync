require "net/http"
require "uri"
require "json"

class ApifyClient
  class TimeoutError < StandardError; end
  class RateLimitedError < StandardError; end

  ENDPOINT = "https://api.apify.com/v2/actors/apify~instagram-post-scraper/run-sync-get-dataset-items".freeze
  DEFAULT_RESULTS_LIMIT = 10
  OPEN_TIMEOUT = 60
  READ_TIMEOUT = 340

  def self.fetch_account(handle, http: nil)
    new(handle, http: http).fetch_account
  end

  def initialize(handle, http: nil)
    @handle = handle
    @http = http
  end

  def fetch_account
    uri = URI.parse(ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      "username" => [ @handle ],
      "resultsLimit" => results_limit
    )

    handle_response(http_for(uri).request(request))
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise TimeoutError, "Apify request timed out: #{e.class}: #{e.message}"
  end

  private

  def http_for(uri)
    http = @http || Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end

  def handle_response(response)
    case response
    when Net::HTTPSuccess
      posts = JSON.parse(response.body)
      unless posts.is_a?(Array)
        raise "unexpected Apify response: expected a JSON array of posts, got #{posts.class}"
      end
      posts
    when Net::HTTPRequestTimeOut
      raise TimeoutError, "Apify run exceeded the 300s sync ceiling (HTTP 408)"
    when Net::HTTPTooManyRequests
      raise RateLimitedError, "Apify rate limited (HTTP 429)"
    else
      raise RateLimitedError, "Apify run failed: HTTP #{response.code} #{response.message} #{response.body.to_s[0, 200]}"
    end
  end

  def token
    value = ENV["APIFY_API_TOKEN"].to_s.strip
    raise "APIFY_API_TOKEN is not set" if value.empty?

    value
  end

  def results_limit
    raw = ENV["APIFY_RESULTS_LIMIT"].to_s
    return DEFAULT_RESULTS_LIMIT if raw.empty?

    Integer(raw)
  end
end
