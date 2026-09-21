# Prompt text + JSON response schema + VERSION. v0 is written straight from
# the plan's §7.2 rules (the practice run, Pass S, may reword after real
# outputs); VERSION is bumped by hand and stored as `extractions.prompt_version`.
#
# Pure: builds strings and hashes, never touches the DB or network.
class ExtractionPrompt
  VERSION = "v0".freeze
  TIMEZONE = "Asia/Kuala_Lumpur".freeze
  SEED = 12345
  # 3.5-flash runs thinking on by default (medium). "low" trims the billed
  # thought tokens and latency; extraction doesn't need deep reasoning.
  THINKING_LEVEL = "low".freeze

  BOOLEAN_SCHEMA = { "type" => "boolean" }.freeze
  NUMBER_SCHEMA = { "type" => "number" }.freeze
  NULLABLE_STRING_SCHEMA = { "type" => "string", "nullable" => true }.freeze
  NULLABLE_BOOLEAN_SCHEMA = { "type" => "boolean", "nullable" => true }.freeze

  CHECKS_SCHEMA = {
    "type" => "object",
    "properties" => {
      "has_date" => BOOLEAN_SCHEMA,
      "has_time" => BOOLEAN_SCHEMA,
      "has_venue" => BOOLEAN_SCHEMA,
      "asks_signup" => BOOLEAN_SCHEMA,
      "asks_donation" => BOOLEAN_SCHEMA,
      "qr_code_seen" => BOOLEAN_SCHEMA
    },
    "required" => %w[has_date has_time has_venue asks_signup asks_donation qr_code_seen]
  }.freeze

  CONFIDENCE_SCHEMA = {
    "type" => "object",
    "properties" => {
      "title" => NUMBER_SCHEMA,
      "starts_at" => NUMBER_SCHEMA,
      "venue" => NUMBER_SCHEMA
    },
    "required" => %w[title starts_at venue]
  }.freeze

  SCHEMA_PROPERTY_ORDER = %w[
    checks category category_confidence title starts_date starts_time ends_date
    ends_time venue registration_url registration_via members_only online_only
    confidence notes
  ].freeze

  SCHEMA = {
    "type" => "object",
    "properties" => {
      "checks" => CHECKS_SCHEMA,
      "category" => { "type" => "string", "enum" => Categories.all },
      "category_confidence" => NUMBER_SCHEMA,
      "title" => NULLABLE_STRING_SCHEMA,
      "starts_date" => NULLABLE_STRING_SCHEMA,
      "starts_time" => NULLABLE_STRING_SCHEMA,
      "ends_date" => NULLABLE_STRING_SCHEMA,
      "ends_time" => NULLABLE_STRING_SCHEMA,
      "venue" => NULLABLE_STRING_SCHEMA,
      "registration_url" => NULLABLE_STRING_SCHEMA,
      "registration_via" => { "type" => "string", "enum" => %w[link qr], "nullable" => true },
      "members_only" => NULLABLE_BOOLEAN_SCHEMA,
      "online_only" => NULLABLE_BOOLEAN_SCHEMA,
      "confidence" => CONFIDENCE_SCHEMA,
      "notes" => NULLABLE_STRING_SCHEMA
    },
    "required" => SCHEMA_PROPERTY_ORDER,
    "propertyOrdering" => SCHEMA_PROPERTY_ORDER
  }.freeze

  SYSTEM_INSTRUCTION = <<~PROMPT.freeze
    You classify Instagram posts from university clubs into categories and extract event details. Answer only as JSON matching the schema.

    EVENT TEST: A post is an event if it tells people about something happening at a specific time and/or place that they can attend or join (booth, workshop, talk, workout, volunteer night, fundraising booth, members-only or online-only event all count). "Date TBA" counts when a venue or other attendable detail is given. An announcement of an upcoming event counts; a follow-up that only restates or counts down to an already-announced event does not — that is a "reminder".

    NOT events: committee/club recruitment, recaps of past events, merch sales, deadlines, teasers ("something big is coming" with no time and no place), and reminder/countdown follow-ups pointing at an already-announced event.

    PRECEDENCE: if the post gives a specific time and/or place people can attend or join, the category is ALWAYS "event" regardless of topic — even if it also asks for sign-ups or donations. Topic categories ("fundraising", "recruitment", ...) apply only when there is no attendable time or place.

    CATEGORIES (exactly one): event, reminder, fundraising, recruitment, recap, merch_or_sales, deadline, teaser, general_announcement, other.

    SIGN-UPS are an attribute of an event, never a category and never the event's date. A sign-up or booth window mentioned inside another event's post is not that event's date.

    DATES: accept only Gregorian dates, in any language of the caption: written month names or day-first numerics ("21/9/2026" = 21 September 2026). Hijri, lunar, or any other calendar → null. Never invent a date. A month/day without a year ("13 Feb") or a day-name reference ("tomorrow", "this Saturday") resolves to the NEAREST occurrence at-or-after the post's date — that is often the announcement's only date. Countdown phrasing ("2 days left", "3 days to go") never produces a date — that is the signature of a "reminder" follow-up and gets no event date. If a date could mean a sign-up deadline → null.

    FORMAT: starts_date / ends_date are always "YYYY-MM-DD"; starts_time / ends_time are always "HH:MM" in 24-hour local wall-clock time, null when no time is given. Multi-day with daily hours → first day's start and last day's end. Overnight → ends_date on the next day.

    SEVERAL EVENTS: report the main (first) one and say so in the notes field.

    LANGUAGE & SOURCES: captions and posters may be English, Malay, Chinese, Arabic, Tamil, or mixed. Copy title and venue exactly as written (title from the caption, venue as written). Poster text wins for date, time and venue; caption wins for title; a conflict lowers confidence. A QR code is only a hint that the post is a sign-up-bearing event poster — never guess where it points. registration_url must come from caption text only.

    NULL OVER GUESSING: use null rather than guessing, and report low confidence rather than silence. confidence is always a number 0-1 per field (title, starts_at, venue); category_confidence is 0-1.
  PROMPT

  def self.generation_config
    {
      "temperature" => 0,
      "seed" => SEED,
      "thinkingConfig" => { "thinkingLevel" => THINKING_LEVEL },
      "responseMimeType" => "application/json",
      "responseSchema" => SCHEMA
    }
  end

  def self.system_instruction
    SYSTEM_INSTRUCTION
  end

  def self.user_text(caption:, posted_at:, timezone: TIMEZONE)
    date = posted_at.in_time_zone(timezone).to_date
    <<~TEXT.strip
      Instagram post, captioned:
      #{caption.to_s.strip}

      Posted: #{date.iso8601} (#{date.strftime("%A")}), local wall-clock time in #{timezone}.

      Examine the caption and the attached image(s). Resolve relative dates against the posted date above. Classify and extract per the schema, emitting checks first.
    TEXT
  end
end
