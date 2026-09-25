# Pure rule checks on the parser's canonical attributes (plan §8). Runs
# regardless of what the LLM reports; posts still advance to `extracted`,
# bad fields just become nil or low-confidence. Never touches the DB.
class ConfidenceThreshold
  PLACEHOLDER_PATTERN = /\A\s*(?:tba|tbd|tbc|na|n\/a|unknown|-)\s*\z/i
  MIN_VENUE_LENGTH = 2
  MAX_VENUE_LENGTH = 200
  MAX_DAYS_BEFORE = 14
  MAX_MONTHS_AFTER = 12

  def self.apply(attributes, posted_at: nil)
    new.apply(attributes, posted_at: posted_at)
  end

  # Returns a new attribute hash (input is not mutated).
  def apply(attributes, posted_at: nil)
    thresholded = attributes.dup
    thresholded[:confidence] = thresholded[:confidence] ? thresholded[:confidence].dup : {}
    thresholded[:venue], thresholded[:confidence][:venue] = sanitize_venue(
      thresholded[:venue],
      thresholded[:confidence].fetch(:venue, 0.0)
    )
    drop_ends_before_start(thresholded)
    cap_starts_at_beyond_window(thresholded, posted_at && posted_at.to_date)
    thresholded
  end

  private

  # Empty, out-of-range, or placeholder venues are not venues: nil + 0.0.
  def sanitize_venue(venue, confidence)
    return [ nil, 0.0 ] unless venue.is_a?(String)
    return [ nil, 0.0 ] if venue.strip.empty?
    return [ nil, 0.0 ] if venue.strip.length < MIN_VENUE_LENGTH || venue.strip.length > MAX_VENUE_LENGTH
    return [ nil, 0.0 ] if venue.match?(PLACEHOLDER_PATTERN)

    [ venue, confidence ]
  end

  # ends_on earlier than starts_on is dropped entirely (plan §8); an end
  # with no start at all is also dropped, since a lone end violates the
  # events check constraint ("ends_on IS NULL OR starts_on IS NOT NULL").
  def drop_ends_before_start(attributes)
    return unless attributes[:ends_date]

    if attributes[:starts_date].nil? || attributes[:ends_date] < attributes[:starts_date]
      attributes[:ends_date] = nil
      attributes[:ends_time] = nil
    end
  end

  # Keep the value, force starts_at confidence to 0.0 when it falls outside
  # the sanity window (Q6: reference is posted_at; past events are still
  # stored). 14 days before, 12 months after.
  def cap_starts_at_beyond_window(attributes, posted_date)
    starts_date = attributes[:starts_date]
    return unless starts_date && posted_date

    if starts_date < posted_date - MAX_DAYS_BEFORE.days || starts_date > (posted_date >> MAX_MONTHS_AFTER)
      attributes[:confidence][:starts_at] = 0.0
    end
  end
end
