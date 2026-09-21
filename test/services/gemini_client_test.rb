require "test_helper"

class GeminiClientTest < ActiveSupport::TestCase
  API_KEY = "gemini_api_test_key".freeze
  MODEL = "gemini-3.8-flash".freeze

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
  end

  def teardown
    ENV.delete("GEMINI_API_KEY")
    ENV.delete("GEMINI_MODEL")
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

  private

  def assert_request_shape(request)
    assert request.is_a?(Net::HTTP::Post)
    assert_equal API_KEY, request["x-goog-api-key"]
    assert_equal "application/json", request["Content-Type"]
  end
end
