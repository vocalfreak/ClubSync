# The closed category list and its `event?` mapping — the single source of
# truth for both the response schema enum (the exact strings the extraction LLM
# picks from) and the `is_event` derivation.
# Category list frozen 2026-09-21; `club_and_society_registration_week` added
# 2026-09-24 (CSRW, Club & Society Registration Week — a real, attendable
# week, never surfaced as an event card; some clubs write "Recruitment Week").
# Changing `event?` later means re-deriving `is_event` from stored data,
# never re-calling Gemini (plan §3, §6).
class Categories
  EVENT = "event".freeze
  CSRW = "club_and_society_registration_week".freeze
  REMINDER = "reminder".freeze
  FUNDRAISING = "fundraising".freeze
  RECRUITMENT = "recruitment".freeze
  RECAP = "recap".freeze
  MERCH_OR_SALES = "merch_or_sales".freeze
  DEADLINE = "deadline".freeze
  TEASER = "teaser".freeze
  GENERAL_ANNOUNCEMENT = "general_announcement".freeze
  OTHER = "other".freeze

  ALL = [
    EVENT,
    CSRW,
    REMINDER,
    FUNDRAISING,
    RECRUITMENT,
    RECAP,
    MERCH_OR_SALES,
    DEADLINE,
    TEASER,
    GENERAL_ANNOUNCEMENT,
    OTHER
  ].freeze

  EVENT_CATEGORIES = [ EVENT ].freeze

  def self.include?(category)
    ALL.include?(category)
  end

  def self.all
    ALL
  end

  def self.event?(category)
    EVENT_CATEGORIES.include?(category)
  end
end
