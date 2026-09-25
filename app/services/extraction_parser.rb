# Pure: Gemini's JSON → canonical attributes + Result. Mirrors
# PostAdapter's contract — never touches the DB, never raises on malformed
# input, and reports shape/type/semantic-value errors instead of deciding
# anything. The response schema guarantees shape, not truth (plan §6 step 4):
# a structurally valid but impossible date (e.g. 2026-02-30) is a failed
# (this-post) parse, exactly like a truncated JSON token.
class ExtractionParser
  class Result
    attr_reader :attributes, :errors

    def initialize(attributes:, errors:, fatal:)
      @attributes = attributes
      @errors = errors
      @fatal = fatal
    end

    def valid?
      !fatal? && errors.empty?
    end

    def fatal?
      @fatal
    end
  end

  REQUIRED_KEYS = %w[
    checks category category_confidence title starts_date starts_time ends_date
    ends_time venue registration_url registration_via members_only online_only
    confidence notes tags
  ].freeze

  DATE_FORMAT = "%Y-%m-%d".freeze
  TIME_PATTERN = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  CHECK_KEYS = %w[has_date has_time has_venue asks_signup asks_donation qr_code_seen].freeze
  CONFIDENCE_KEYS = %w[title starts_at venue].freeze

  NOT_AN_OBJECT = "response must be a JSON object".freeze
  MISSING_KEYS = "response is missing required keys: %s".freeze

  def parse(raw_hash)
    return Result.new(attributes: nil, errors: [ NOT_AN_OBJECT ], fatal: true) unless raw_hash.is_a?(Hash)

    @raw = raw_hash
    @attributes = {}
    @errors = []

    missing = REQUIRED_KEYS.reject { |key| @raw.key?(key) }
    if missing.any?
      return Result.new(attributes: nil, errors: [ format(MISSING_KEYS, missing.join(", ")) ], fatal: true)
    end

    map_checks
    @attributes[:category] = map_enum("category", Categories.all)
    @attributes[:category_confidence] = map_number("category_confidence")
    @attributes[:is_event] = Categories.event?(@attributes[:category])
    @attributes[:title] = map_string("title")
    @attributes[:starts_date] = map_date("starts_date")
    @attributes[:starts_time] = map_time("starts_time")
    @attributes[:ends_date] = map_date("ends_date")
    @attributes[:ends_time] = map_time("ends_time")
    @attributes[:venue] = map_string("venue")
    @attributes[:registration_url] = map_string("registration_url")
    @attributes[:registration_via] = map_enum("registration_via", %w[link qr].freeze)
    @attributes[:members_only] = map_boolean("members_only")
    @attributes[:online_only] = map_boolean("online_only")
    @attributes[:confidence] = map_confidence
    @attributes[:notes] = map_string("notes")
    @attributes[:tags] = map_tags

    Result.new(attributes: @attributes, errors: @errors, fatal: false)
  end

  private

  def map_checks
    checks = @raw["checks"]
    if checks.is_a?(Hash) && CHECK_KEYS.all? { |key| checks[key] == true || checks[key] == false || checks[key].nil? }
      @attributes[:checks] = checks
    else
      @errors << "checks must be an object with boolean keys: #{CHECK_KEYS.join(", ")}"
      @attributes[:checks] = nil
    end
  end

  def map_enum(key, allowed)
    value = @raw[key]
    return nil if value.nil?

    unless allowed.include?(value)
      @errors << "#{key} must be one of: #{allowed.join(", ")} (got #{value.inspect})"
      return value
    end

    value
  end

  def map_number(key)
    value = @raw[key]
    return nil if value.nil?

    number = Float(value)
    [ [ number, 0.0 ].max, 1.0 ].min
  rescue ArgumentError, TypeError
    @errors << "#{key} must be a number (got #{value.inspect})"
    nil
  end

  def map_string(key)
    value = @raw[key]
    return nil if value.nil?

    unless value.is_a?(String)
      @errors << "#{key} must be a string or null (got #{value.inspect})"
      return nil
    end

    value
  end

  def map_date(key)
    value = @raw[key]
    return nil if value.nil?

    unless value.is_a?(String)
      @errors << "#{key} must be a YYYY-MM-DD string or null (got #{value.inspect})"
      return nil
    end

    Date.strptime(value, DATE_FORMAT)
  rescue Date::Error
    @errors << "#{key} is not a real calendar date (got #{value.inspect})"
    nil
  end

  def map_time(key)
    value = @raw[key]
    return nil if value.nil?

    unless value.is_a?(String) && value.match?(TIME_PATTERN)
      @errors << "#{key} must be a HH:MM string or null (got #{value.inspect})"
      return nil
    end

    value
  end

  def map_boolean(key)
    value = @raw[key]
    return nil if value.nil?

    unless value == true || value == false
      @errors << "#{key} must be a boolean or null (got #{value.inspect})"
      return nil
    end

    value
  end

  def map_tags
    value = @raw["tags"]
    return [] if value.nil?

    unless value.is_a?(Array)
      @errors << "tags must be an array of strings (got #{value.inspect})"
      return []
    end

    # Lenient on values (plan grill 2026-09-25): out-of-list tags are dropped,
    # never a parse failure — a filter-UI convenience, not a business gate.
    value.select { |tag| EventTags.include?(tag) }.uniq
  end

  def map_confidence
    value = @raw["confidence"]
    unless value.is_a?(Hash)
      @errors << "confidence must be an object with number keys: #{CONFIDENCE_KEYS.join(", ")}"
      return {}
    end

    CONFIDENCE_KEYS.to_h { |key| [ key.to_sym, map_confidence_number("confidence.#{key}", value[key]) ] }
  end

  def map_confidence_number(key, value)
    return 0.0 if value.nil?

    number = Float(value)
    [ [ number, 0.0 ].max, 1.0 ].min
  rescue ArgumentError, TypeError
    @errors << "#{key} must be a number (got #{value.inspect})"
    0.0
  end
end
