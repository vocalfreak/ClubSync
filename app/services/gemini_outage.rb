# Run-level Gemini outage tracker (plan §5.3). Pure, in-memory, one per run:
# counts consecutive whole-service extraction failures and becomes active at 5,
# after which the rest of the run skips `Extractor` entirely (posts wait at
# `media_processed` for the next cron pass). Any non-whole-service outcome —
# a success, a this-post failure, or a skip — resets the count, since the
# service answered in each of those cases. Never persisted.
class GeminiOutage
  THRESHOLD = 5

  attr_reader :consecutive_failures

  def initialize(threshold: THRESHOLD)
    @threshold = threshold
    @consecutive_failures = 0
    @just_started = false
  end

  def active?
    @consecutive_failures >= @threshold
  end

  # Latched true from the moment the outage becomes active until the streak
  # resets. The caller reads it exactly once (runner ensure), so no alert is
  # lost when another failure lands after the flip but before the run ends.
  def just_started?
    @just_started
  end

  # Feed it an `Extractor::Result` after each extraction attempt. A
  # whole-service failure accumulates; anything else (success, this-post
  # failure, skip) resets the streak.
  def record(result)
    if result.failed? && result.error_kind == :whole_service
      @consecutive_failures += 1
      @just_started = true if @consecutive_failures == @threshold
    else
      @consecutive_failures = 0
      @just_started = false
    end

    self
  end
end
