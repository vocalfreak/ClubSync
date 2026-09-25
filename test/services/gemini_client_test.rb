require "test_helper"

class GeminiClientTest < ActiveSupport::TestCase
  API_KEY = "gemini_api_test_key".freeze
  MODEL = "gemini-3.8-flash".freeze
  EMBED_MODEL = "gemini-embedding-2".freeze

  SUCCESS_BODY = JSON.generate(
    "candidates" => [
      {
        "finishReason" => "STOP",
        "content" => { "parts" => [ { "text" => JSON.generate("category" => "event", "title" => "Riddim night") } ] }
      }
    ],
    "usageMetadata" => {
      "promptTokenCount" => 412,
      "candidatesTokenCount" => 61,
      "totalTokenCount" => 473
    },
    "modelVersion" => "gemini-3.8-flash"
  ).freeze

  EMBED_SUCCESS_BODY = JSON.generate(
    "embedding" => { "values" => [ 0.1, -0.2, 0.95, 0.0004 ] },
    "modelVersion" => "gemini-embedding-2"
  ).freeze

  CONTENTS = [
    { "role" => "user", "parts" => [ { "text" => "Classify this post." } ] }
  ].freeze

  GENERATION_CONFIG = {
    "responseMimeType" => "application/json",
    "responseSchema" => { "type" => "object" }
  }.freeze

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
    ENV["GEMINI_API_KEY"] = API_KEY
    ENV["GEMINI_MODEL"] = MODEL
    ENV["GEMINI_EMBED_MODEL"] = EMBED_MODEL
  end

  def teardown
    ENV.delete("GEMINI_API_KEY")
    ENV.delete("GEMINI_MODEL")
    ENV.delete("GEMINI_EMBED_MODEL")
  end

  def build_response(klass, code, message, body: nil)
    response = klass.new("1.1", code, message)
    response.instance_variable_set(:@read, true)
    response.body = body unless body.nil?
    response
  end

  def extract(http:, model: nil, **kwargs)
    GeminiClient.extract(contents: CONTENTS, generation_config: GENERATION_CONFIG, model: model, http: http, **kwargs)
  end

  test "sends a generateContent request and returns a parsed response" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: SUCCESS_BODY))

    response = extract(http: http)

    assert_equal({ "category" => "event", "title" => "Riddim night" }, response.parsed)
    assert_equal 412, response.prompt_tokens
    assert_equal 61, response.candidates_tokens
    assert_equal MODEL, response.model
    assert response.duration_ms.is_a?(Integer)
    assert http.use_ssl
    assert http.open_timeout.positive?
    assert http.read_timeout.positive?

    request = http.last_request
    assert_request_shape(request)
    body = JSON.parse(request.body)
    assert_equal CONTENTS, body["contents"]
    assert_equal GENERATION_CONFIG, body["generationConfig"]
    assert_nil body["systemInstruction"]
  end

  test "sends the system instruction when given" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: SUCCESS_BODY))

    extract(http: http, system_instruction: "You classify club posts.")

    body = JSON.parse(http.last_request.body)
    assert_equal({ "parts" => [ { "text" => "You classify club posts." } ] }, body["systemInstruction"])
  end

  test "hits the endpoint for the configured model" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: SUCCESS_BODY))

    extract(http: http)

    assert_equal "/v1beta/models/gemini-3.8-flash:generateContent", http.last_request.path
  end

  test "uses the passed model regardless of GEMINI_MODEL" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: SUCCESS_BODY))

    extract(http: http, model: "gemini-2.5-flash")

    assert_equal "/v1beta/models/gemini-2.5-flash:generateContent", http.last_request.path
  end

  test "raises TimeoutError on an open timeout" do
    http = FakeHTTP.new(error: Net::OpenTimeout)

    error = assert_raises(GeminiClient::TimeoutError) { extract(http: http) }
    assert_match(/Gemini request timed out/, error.message)
  end

  test "raises TimeoutError on a read timeout" do
    http = FakeHTTP.new(error: Net::ReadTimeout)

    error = assert_raises(GeminiClient::TimeoutError) { extract(http: http) }
    assert_match(/Gemini request timed out/, error.message)
  end

  test "raises TimeoutError on HTTP 408" do
    http = FakeHTTP.new(build_response(Net::HTTPRequestTimeOut, "408", "Request Timeout"))

    error = assert_raises(GeminiClient::TimeoutError) { extract(http: http) }
    assert_match(/HTTP 408/, error.message)
  end

  test "raises RateLimitedError on HTTP 429" do
    http = FakeHTTP.new(build_response(Net::HTTPTooManyRequests, "429", "Too Many Requests"))

    error = assert_raises(GeminiClient::RateLimitedError) { extract(http: http) }
    assert_match(/rate limited/, error.message)
  end

  test "raises AuthError on HTTP 401" do
    http = FakeHTTP.new(build_response(Net::HTTPUnauthorized, "401", "Unauthorized"))

    error = assert_raises(GeminiClient::AuthError) { extract(http: http) }
    assert_match(/authentication failed/, error.message)
  end

  test "raises AuthError on HTTP 403" do
    http = FakeHTTP.new(build_response(Net::HTTPForbidden, "403", "Forbidden"))

    error = assert_raises(GeminiClient::AuthError) { extract(http: http) }
    assert_match(/authentication failed/, error.message)
  end

  test "raises ServerError on HTTP 500" do
    body = JSON.generate("error" => { "message" => "backend unavailable" })
    http = FakeHTTP.new(build_response(Net::HTTPInternalServerError, "500", "Internal Server Error", body: body))

    error = assert_raises(GeminiClient::ServerError) { extract(http: http) }
    assert_match(/backend unavailable/, error.message)
  end

  test "raises BlockedError on HTTP 400 with a safety status" do
    body = JSON.generate("error" => { "status" => "SAFETY", "message" => "blocked" })
    http = FakeHTTP.new(build_response(Net::HTTPBadRequest, "400", "Bad Request", body: body))

    error = assert_raises(GeminiClient::BlockedError) { extract(http: http) }
    assert_match(/SAFETY/, error.message)
  end

  test "raises BlockedError on HTTP 400 with a prompt-blocked status" do
    body = JSON.generate("error" => { "status" => "PROMPT_BLOCKED", "message" => "blocked" })
    http = FakeHTTP.new(build_response(Net::HTTPBadRequest, "400", "Bad Request", body: body))

    assert_raises(GeminiClient::BlockedError) { extract(http: http) }
  end

  test "raises InvalidResponseError on an unclassified HTTP 400" do
    body = JSON.generate("error" => { "status" => "INVALID_ARGUMENT", "message" => "schema rejected" })
    http = FakeHTTP.new(build_response(Net::HTTPBadRequest, "400", "Bad Request", body: body))

    error = assert_raises(GeminiClient::InvalidResponseError) { extract(http: http) }
    assert_match(/schema rejected/, error.message)
  end

  test "raises InvalidResponseError on HTTP 404" do
    http = FakeHTTP.new(build_response(Net::HTTPNotFound, "404", "Not Found"))

    assert_raises(GeminiClient::InvalidResponseError) { extract(http: http) }
  end

  test "raises BlockedError when the candidate finishReason is a block reason" do
    body = JSON.generate(
      "candidates" => [
        { "finishReason" => "SAFETY", "content" => { "parts" => [ { "text" => "{}" } ] } }
      ]
    )
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: body))

    error = assert_raises(GeminiClient::BlockedError) { extract(http: http) }
    assert_match(/SAFETY/, error.message)
  end

  test "raises BlockedError when the response has no candidates" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: JSON.generate("candidates" => [])))

    assert_raises(GeminiClient::BlockedError) { extract(http: http) }
  end

  test "raises InvalidResponseError when the candidate text is not JSON" do
    body = JSON.generate(
      "candidates" => [ { "finishReason" => "STOP", "content" => { "parts" => [ { "text" => "not json" } ] } } ]
    )
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: body))

    assert_raises(GeminiClient::InvalidResponseError) { extract(http: http) }
  end

  test "raises InvalidResponseError on a non-JSON success body" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: "not json"))

    assert_raises(GeminiClient::InvalidResponseError) { extract(http: http) }
  end

  test "raises when GEMINI_API_KEY is not configured" do
    ENV.delete("GEMINI_API_KEY")

    error = assert_raises(RuntimeError) { extract(http: FakeHTTP.new) }
    assert_match(/GEMINI_API_KEY is not set/, error.message)
  end

  test "raises when GEMINI_MODEL is not configured" do
    ENV.delete("GEMINI_MODEL")

    error = assert_raises(RuntimeError) { extract(http: FakeHTTP.new) }
    assert_match(/GEMINI_MODEL is not set/, error.message)
  end

  test "embed hits the embedContent endpoint for GEMINI_EMBED_MODEL and returns the vector" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: EMBED_SUCCESS_BODY))

    response = GeminiClient.embed(text: "Riddim night at Memory", http: http)

    assert_equal [ 0.1, -0.2, 0.95, 0.0004 ], response.values
    assert_equal EMBED_MODEL, response.model
    assert_equal "/v1beta/models/gemini-embedding-2:embedContent", http.last_request.path
    assert_request_shape(http.last_request)
  end

  test "embed sends the caption and the full models/ name in the body" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: EMBED_SUCCESS_BODY))

    GeminiClient.embed(text: "Riddim night", http: http)

    body = JSON.parse(http.last_request.body)
    assert_equal "models/gemini-embedding-2", body["model"]
    assert_equal({ "parts" => [ { "text" => "Riddim night" } ] }, body["content"])
  end

  test "embed uses the passed model regardless of GEMINI_EMBED_MODEL" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: EMBED_SUCCESS_BODY))

    GeminiClient.embed(text: "x", model: "gemini-embedding-test", http: http)

    assert_equal "/v1beta/models/gemini-embedding-test:embedContent", http.last_request.path
  end

  test "embed reuses the extract error taxonomy" do
    timeout = FakeHTTP.new(error: Net::OpenTimeout)
    assert_raises(GeminiClient::TimeoutError) { GeminiClient.embed(text: "x", http: timeout) }

    rate_limited = FakeHTTP.new(build_response(Net::HTTPTooManyRequests, "429", "Too Many Requests"))
    assert_raises(GeminiClient::RateLimitedError) { GeminiClient.embed(text: "x", http: rate_limited) }
  end

  test "embed raises InvalidResponseError when the response has no embedding values" do
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: JSON.generate("embedding" => {})))

    assert_raises(GeminiClient::InvalidResponseError) { GeminiClient.embed(text: "x", http: http) }
  end

  test "embed raises when GEMINI_EMBED_MODEL is not configured, even if GEMINI_MODEL is" do
    ENV.delete("GEMINI_EMBED_MODEL")

    error = assert_raises(RuntimeError) { GeminiClient.embed(text: "x", http: FakeHTTP.new) }
    assert_match(/GEMINI_EMBED_MODEL is not set/, error.message)
  end

  test "hard-fails with PayloadTooLargeError when the serialized body exceeds the hard limit" do
    huge = [ { "role" => "user", "parts" => [ { "text" => "x" * GeminiClient::HARD_LIMIT } ] } ]
    http = FakeHTTP.new

    error = assert_raises(GeminiClient::PayloadTooLargeError) { extract(http: http, contents: huge) }

    assert_match(/exceeds the #{GeminiClient::HARD_LIMIT} byte hard limit/, error.message)
    assert_nil http.last_request, "the oversized body never hits the transport"
  end

  test "soft-warns but still sends when the serialized body sits between the soft and hard limits" do
    body = [ { "role" => "user", "parts" => [ { "text" => "x" * GeminiClient::SOFT_LIMIT } ] } ]
    warnings = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:warn) { |msg| warnings << msg }
    http = FakeHTTP.new(build_response(Net::HTTPOK, "200", "OK", body: SUCCESS_BODY))
    original_logger = Rails.logger

    Rails.logger = fake_logger
    begin
      response = extract(http: http, contents: body)
      assert_equal({ "category" => "event", "title" => "Riddim night" }, response.parsed)
    ensure
      Rails.logger = original_logger
    end

    assert_equal 1, warnings.length
    assert_match(/over the #{GeminiClient::SOFT_LIMIT} byte soft limit/, warnings.first)
  end

  private

  def assert_request_shape(request)
    assert request.is_a?(Net::HTTP::Post)
    assert_equal API_KEY, request["x-goog-api-key"]
    assert_equal "application/json", request["Content-Type"]
  end
end
