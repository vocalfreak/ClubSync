require "test_helper"

class ApifyClientTest < ActiveSupport::TestCase
  SAMPLE_POSTS = [
    {
      "shortCode" => "DJ9hbKfMxYZ",
      "ownerUsername" => "itsocietymmu",
      "type" => "Image",
      "caption" => "THIS THURSDAY. Riddim night at Memory. Free entry before 11.",
      "url" => "https://www.instagram.com/p/DJ9hbKfMxYZ/",
      "displayUrl" => "https://scontent.cdninstagram.com/v/t51.2885-15/463591234_1_n.jpg",
      "timestamp" => "2026-09-11T12:00:00.000Z"
    },
    {
      "shortCode" => "DJ7xaQpWvBc",
      "ownerUsername" => "clubhyphasia",
      "type" => "Sidecar",
      "url" => "https://www.instagram.com/p/DJ7xaQpWvBc/",
      "timestamp" => "2026-09-08T17:30:00.000Z"
    }
  ].freeze

  API_TOKEN = "apify_api_test_token".freeze

  class FakeHTTP
    attr_reader :use_ssl, :open_timeout, :read_timeout, :last_request

    def initialize(response = nil, error: nil)
      @response = response
      @error = error
    end

    def use_ssl=(value)
      @use_ssl = value
    end

    def open_timeout=(value)
      @open_timeout = value
    end

    def read_timeout=(value)
      @read_timeout = value
    end

    def request(request)
      @last_request = request
      raise @error if @error

      @response
    end
  end

  def setup
    ENV["APIFY_API_TOKEN"] = API_TOKEN
    ENV.delete("APIFY_RESULTS_LIMIT")
  end

  def teardown
    ENV.delete("APIFY_API_TOKEN")
    ENV.delete("APIFY_RESULTS_LIMIT")
  end

  def build_response(klass, code, message, body: nil)
    response = klass.new("1.1", code, message)
    response.instance_variable_set(:@read, true)
    response.body = body unless body.nil?
    response
  end

  def fetch(handle = "stimpflipevents", http:)
    ApifyClient.fetch_account(handle, http: http)
  end

  test "fetch_account returns the parsed array of post payloads on a successful run" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: JSON.generate(SAMPLE_POSTS)))

    posts = fetch(http: http)

    assert_equal SAMPLE_POSTS, posts
    assert http.use_ssl
    assert http.open_timeout.positive?
    assert http.read_timeout.positive?
    assert http.last_request.is_a?(Net::HTTP::Post)
    assert_equal "/v2/actors/apify~instagram-post-scraper/run-sync-get-dataset-items", http.last_request.path
    assert_equal "Bearer #{API_TOKEN}", http.last_request["Authorization"]
    assert_equal "application/json", http.last_request["Content-Type"]
    assert_equal({ "username" => [ "stimpflipevents" ], "resultsLimit" => 15 }, JSON.parse(http.last_request.body))
  end

  test "honours a configured APIFY_RESULTS_LIMIT in the actor input" do
    ENV["APIFY_RESULTS_LIMIT"] = "12"
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: "[]"))

    fetch(http: http)

    assert_equal 12, JSON.parse(http.last_request.body)["resultsLimit"]
  end

  test "defaults the actor input username array to the requested handle" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: "[]"))

    fetch("clubbanghaus", http: http)

    assert_equal({ "username" => [ "clubbanghaus" ], "resultsLimit" => 15 }, JSON.parse(http.last_request.body))
  end

  test "raises TimeoutError on an open timeout" do
    http = FakeHTTP.new(error: Net::OpenTimeout)

    error = assert_raises(ApifyClient::TimeoutError) { fetch(http: http) }
    assert_match(/Apify request timed out/, error.message)
  end

  test "raises TimeoutError on a read timeout" do
    http = FakeHTTP.new(error: Net::ReadTimeout)

    error = assert_raises(ApifyClient::TimeoutError) { fetch(http: http) }
    assert_match(/Apify request timed out/, error.message)
  end

  test "raises TimeoutError when Apify cuts the run off at its 300s sync ceiling (HTTP 408)" do
    http = FakeHTTP.new(build_response(Net::HTTPRequestTimeOut, "408", "Request Timeout"))

    error = assert_raises(ApifyClient::TimeoutError) { fetch(http: http) }
    assert_match(/sync ceiling/, error.message)
  end

  test "raises RateLimitedError on HTTP 429" do
    http = FakeHTTP.new(build_response(Net::HTTPTooManyRequests, "429", "Too Many Requests"))

    error = assert_raises(ApifyClient::RateLimitedError) { fetch(http: http) }
    assert_match(/rate limited/, error.message)
  end

  test "raises RateLimitedError when the run itself failed (HTTP 500)" do
    http = FakeHTTP.new(build_response(Net::HTTPInternalServerError, "500", "Internal Server Error", body: "run failed"))

    error = assert_raises(ApifyClient::RateLimitedError) { fetch(http: http) }
    assert_match(/run failed.*HTTP 500/, error.message)
  end

  test "a non-JSON success body raises the parser error as an unanticipated bug" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: "not json"))

    assert_raises(JSON::ParserError) { fetch(http: http) }
  end

  test "a success body that is not an array raises as an unanticipated bug" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: JSON.generate("data" => [])))

    error = assert_raises(RuntimeError) { fetch(http: http) }
    assert_match(/expected a JSON array of posts/, error.message)
  end

  test "raises when APIFY_API_TOKEN is not configured" do
    ENV.delete("APIFY_API_TOKEN")

    error = assert_raises(RuntimeError) { fetch(http: FakeHTTP.new) }
    assert_match(/APIFY_API_TOKEN is not set/, error.message)
  end
end
