require "net/http"
require "json"

# REST transport for the Gemini generateContent endpoint. Wraps Net::HTTP so
# the pipeline gets the same injectable, hermetic transport pattern as
# ApifyClient. 2026-09-21 decision: plain REST, not the `google-genai` gem
# (that gem is an unofficial 0.1.1 single-author port with no request
# timeouts and error classes that clash with this taxonomy).
class GeminiClient
  # Whole-service failures — the run cannot continue and the outage tracker counts us.
  class TimeoutError < StandardError; end
  class RateLimitedError < StandardError; end
  class AuthError < StandardError; end
  class ServerError < StandardError; end

  # This-post failures — retried by a later run, never fatal to the run.
  class BlockedError < StandardError; end
  class InvalidResponseError < StandardError; end
  class PayloadTooLargeError < StandardError; end

  ENDPOINT_HOST = "generativelanguage.googleapis.com".freeze
  OPEN_TIMEOUT = 30
  READ_TIMEOUT = 120
  # Payload preflight (plan §2): over the serialized request body. Soft-warn
  # (log only) past SOFT_LIMIT; hard-fail past HARD_LIMIT — beyond that Gemini
  # will reject the body anyway, so don't spend the round-trip.
  SOFT_LIMIT = 12 * 1024 * 1024
  HARD_LIMIT = 18 * 1024 * 1024
  BLOCKED_ERROR_STATUSES = %w[SAFETY RECITATION PROMPT_BLOCKED BLOCKED].freeze
  BLOCKED_FINISH_REASONS = %w[SAFETY PROHIBITED_CONTENT BLOCKLIST].freeze

  Response = Struct.new(:text, :parsed, :prompt_tokens, :candidates_tokens, :duration_ms, :model, keyword_init: true)
  EmbedResponse = Struct.new(:values, :model, keyword_init: true)

  # `contents` is the pre-built request body (caption text + inline images);
  # `generation_config` carries the JSON response schema. Both are built by the
  # Pass 2 payload factory — this client is transport only.
  def self.extract(contents:, system_instruction: nil, generation_config: nil, model: nil, http: nil)
    new(model: model, http: http).extract(
      contents: contents,
      system_instruction: system_instruction,
      generation_config: generation_config
    )
  end

  def initialize(model: nil, http: nil, env_key: "GEMINI_MODEL")
    @model = model || ENV[env_key].to_s.strip
    raise "#{env_key} is not set" if @model.empty?

    @http = http
  end

  # The embedding sibling of `extract` (dedup plan §3): hits
  # `models/<model>:embedContent` and returns a vector instead of candidates,
  # so it shares the error taxonomy and the injectable-http pattern but is not
  # a fork of the generateContent path. The model comes from a separate
  # GEMINI_EMBED_MODEL env key — reuse of GEMINI_MODEL is forbidden.
  def self.embed(text:, model: nil, http: nil)
    new(model: model, http: http, env_key: "GEMINI_EMBED_MODEL").embed(text: text)
  end

  def extract(contents:, system_instruction: nil, generation_config: nil)
    serialized = request_body(contents: contents, system_instruction: system_instruction, generation_config: generation_config)
    preflight_size!(serialized)

    uri = URI.parse("https://#{ENDPOINT_HOST}/v1beta/models/#{@model}:generateContent")
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    handle_response(http_for(uri).request(build_request(uri, serialized)), started_at)
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise TimeoutError, "Gemini request timed out: #{e.class}: #{e.message}"
  end

  # Shared body assembly: the same bytes the transport sends, exposed so local
  # tools (e.g. the payload-measurement rake task) can measure without a network
  # call. Public and idempotent.
  def self.request_body(contents:, system_instruction: nil, generation_config: nil)
    body = { contents: contents }
    body[:systemInstruction] = { parts: [ { text: system_instruction } ] } if system_instruction
    body[:generationConfig] = generation_config if generation_config
    JSON.generate(body)
  end

  def embed(text:)
    serialized = request_body_for_embed(text)
    preflight_size!(serialized)
    uri = URI.parse("https://#{ENDPOINT_HOST}/v1beta/models/#{@model}:embedContent")
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    handle_embed_response(http_for(uri).request(build_request(uri, serialized)), started_at)
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise TimeoutError, "Gemini request timed out: #{e.class}: #{e.message}"
  end

  private

  def request_body_for_embed(text)
    JSON.generate(model: "models/#{@model}", content: { parts: [ { text: text } ] })
  end

  def handle_embed_response(response, started_at)
    raise_error_for(response) unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response.body, "Gemini returned non-JSON")
    values = data.dig("embedding", "values")
    raise InvalidResponseError, "Gemini returned no embedding values" if values.nil? || values.empty?

    EmbedResponse.new(values: values, model: data["modelVersion"] || @model)
  end

  def request_body(contents:, system_instruction: nil, generation_config: nil)
    self.class.request_body(contents: contents, system_instruction: system_instruction, generation_config: generation_config)
  end

  def preflight_size!(serialized)
    bytes = serialized.bytesize
    if bytes >= HARD_LIMIT
      raise PayloadTooLargeError,
            "Gemini payload too large: #{bytes} bytes exceeds the #{HARD_LIMIT} byte hard limit"
    end

    Rails.logger.warn("Gemini payload is #{bytes} bytes, over the #{SOFT_LIMIT} byte soft limit") if bytes >= SOFT_LIMIT
  end

  def build_request(uri, serialized)
    request = Net::HTTP::Post.new(uri)
    request["x-goog-api-key"] = api_key
    request["Content-Type"] = "application/json"
    request.body = serialized
    request
  end

  def http_for(uri)
    http = @http || Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end

  def api_key
    value = ENV["GEMINI_API_KEY"].to_s.strip
    raise "GEMINI_API_KEY is not set" if value.empty?

    value
  end

  def handle_response(response, started_at)
    raise_error_for(response) unless response.is_a?(Net::HTTPSuccess)

    parse_success(response, started_at)
  end

  def raise_error_for(response)
    case response
    when Net::HTTPUnauthorized, Net::HTTPForbidden
      raise AuthError, "Gemini authentication failed (HTTP #{response.code})"
    when Net::HTTPTooManyRequests
      raise RateLimitedError, "Gemini rate limited (HTTP 429)"
    when Net::HTTPRequestTimeOut
      raise TimeoutError, "Gemini request timed out (HTTP 408)"
    when Net::HTTPServerError
      raise ServerError, "Gemini server error (HTTP #{response.code}): #{error_message(response)}"
    else
      status = error_status(response)
      raise BlockedError, "Gemini blocked the prompt (HTTP #{response.code}, #{status})" if BLOCKED_ERROR_STATUSES.include?(status)

      raise InvalidResponseError, "Gemini rejected the request (HTTP #{response.code}): #{error_message(response)}"
    end
  end

  def parse_success(response, started_at)
    data = parse_json(response.body, "Gemini returned non-JSON")
    candidate = data["candidates"]&.first

    raise BlockedError, "Gemini returned no candidates" if candidate.nil?
    if BLOCKED_FINISH_REASONS.include?(candidate["finishReason"])
      raise BlockedError, "Gemini blocked the prompt (finishReason #{candidate["finishReason"]})"
    end

    text = Array(candidate.dig("content", "parts")).map { |part| part["text"] }.compact.join
    parsed = parse_json(text, "Gemini returned unparseable JSON in the candidate text")

    usage = data["usageMetadata"] || {}
    Response.new(
      text: text,
      parsed: parsed,
      prompt_tokens: usage["promptTokenCount"],
      candidates_tokens: usage["candidatesTokenCount"],
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round,
      model: data["modelVersion"] || @model
    )
  end

  def parse_json(raw, message)
    JSON.parse(raw)
  rescue JSON::ParserError => e
    raise InvalidResponseError, "#{message}: #{e.message}"
  end

  def error_status(response)
    JSON.parse(response.body).dig("error", "status")
  rescue JSON::ParserError, TypeError
    nil
  end

  def error_message(response)
    JSON.parse(response.body).dig("error", "message") || response.body.to_s[0, 200]
  rescue JSON::ParserError, TypeError
    response.body.to_s[0, 200]
  end
end
