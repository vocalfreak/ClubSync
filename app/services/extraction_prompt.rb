# Prompt text + JSON response schema + VERSION. v0 is written straight from
# the plan's §7.2 rules (the practice run, Pass S, may reword after real
# outputs); VERSION is bumped by hand and stored as `extractions.prompt_version`.
# v1 (2026-09-24): added the CSRW category (outranks event — booth/week posts
# are csrw, never event cards).
# v2 (2026-09-24): renamed the category value to `club_and_society_registration_week`
# (the descriptive value the model picks on), anchored all caption spellings +
# the "recruitment week" synonym, and added the boundary axis + few-shot
# cheat sheet.
# v3 (2026-09-24): recap-wins precedence (a post that only re-points at an
# already-announced event is reminder/recap, never an event card — fixes
# DdI3NLXHeYN), and qr_code_seen is true only when a clearly visible QR code is
# actually printed in an image, never inferred from caption wording — fixes
# Dc0xZzTzRDJ's false positive.
#
# Pure: builds strings and hashes, never touches the DB or network.
class ExtractionPrompt
  VERSION = "v3".freeze
  TIMEZONE = "Asia/Kuala_Lumpur".freeze
  SEED = 12345
  # 3.5-flash runs thinking on by default (medium). "low" trims the billed
  # thought tokens and latency; extraction doesn't need deep reasoning. Env-
  # overridable ("high" for A/B eval) without touching the prompt content —
  # VERSION stays the prompt's, not the runtime config's.
  THINKING_LEVEL = ENV.fetch("GEMINI_THINKING_LEVEL", "low").freeze

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

    PRECEDENCE: if the post gives a specific time and/or place people can attend or join, the category is ALWAYS "event" regardless of topic — even if it also asks for sign-ups or donations. Topic categories ("fundraising", "recruitment", ...) apply only when there is no attendable time or place. EXCEPTION: a Club & Society Registration Week booth (below) is #{Categories::CSRW}, never "event". RECAP WINS: a post that only re-points at an already-announced event — a reminder/countdown, a thank-you, or a post-event recap restating the past date/venue — is never "event"; it is "reminder" or "recap" even though it names that time and place. A recap that additionally announces a NEW upcoming session with its own time/place IS an event.

    BUILDING THE WEEK CATEGORY "#{Categories::CSRW}": Club & Society Registration Week is the annual university-wide welcome week; captions may write "CSRW", "Club & Society Registration Week", "Club and Society Recruitment Week", or just mention "registration week". A post is #{Categories::CSRW} when it is ABOUT the week itself: the week's own invites, a club's booth/lucky-draw promo "during CSRW", sign-ups for the booth, and the post-week thank-you/recap. #{Categories::CSRW} always outranks "event" for such content, even when it names a booth, time or place. A post ONLY about some other standalone event that happens to land in that week, unrelated to registration (a troupe's show, a talk), stays "event" — it is attended, not a registration statement.

    CATEGORIES (exactly one of): #{Categories.all.join(", ")}.

    CHEAT SHEET — decide like this:
      "Come find our booth during CSRW! CLC, 10am-5pm" => #{Categories::CSRW}
      "Thanks to everyone who visited our booth at CSRW!" => #{Categories::CSRW}
      "Tickets for our production, 5 Nov, Kancil Hall" => event
      "Join our committee - no experience needed" => recruitment
      "2 days left to register for the battle!" => reminder
      "Huge thanks to everyone who came to our charity night last Friday!" => recap

    SIGN-UPS are an attribute of an event, never a category and never the event's date. A sign-up or booth window mentioned inside another event's post is not that event's date.

    DATES: accept only Gregorian dates, in any language of the caption: written month names or day-first numerics ("21/9/2026" = 21 September 2026). Hijri, lunar, or any other calendar → null. Never invent a date. A month/day without a year ("13 Feb") or a day-name reference ("tomorrow", "this Saturday") resolves to the NEAREST occurrence at-or-after the post's date — that is often the announcement's only date. Countdown phrasing ("2 days left", "3 days to go") never produces a date — that is the signature of a "reminder" follow-up and gets no event date. If a date could mean a sign-up deadline → null.

    FORMAT: starts_date / ends_date are always "YYYY-MM-DD"; starts_time / ends_time are always "HH:MM" in 24-hour local wall-clock time, null when no time is given. Multi-day with daily hours → first day's start and last day's end. Overnight → ends_date on the next day.

    SEVERAL EVENTS: report the main (first) one and say so in the notes field.

    LANGUAGE & SOURCES: captions and posters may be English, Malay, Chinese, Arabic, Tamil, or mixed. Copy title and venue exactly as written (title from the caption, venue as written). Poster text wins for date, time and venue; caption wins for title; a conflict lowers confidence. qr_code_seen is true ONLY when a clearly visible QR code is actually printed in one of the images — never inferred from context, from "scan", "QR" or "register at" wording in the caption, or from a sign-up link. registration_url must come from caption text only.

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
