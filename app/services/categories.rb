# The closed category list and its `event?` mapping — the single source of
# truth for both the response schema enum and the `is_event` derivation.
# Frozen 2026-09-21; changing a category later means re-deriving `is_event`
# from stored data, never re-calling Gemini (plan §3, §6).
class Categories
  EVENT = "event".freeze
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
