# Run-level Gemini circuit breaker (plan §5.3). Pure, in-memory, one per run:
# counts consecutive whole-service extraction failures and opens at 5, after
# which the rest of the run skips `Extractor` entirely (posts wait at
# `media_processed` for the next cron pass). Any non-whole-service outcome —
# a success, a this-post failure, or a skip — resets the count, since the
# service answered in each of those cases. Never persisted.
class GeminiBreaker
  THRESHOLD = 5

  attr_reader :consecutive_failures

  def initialize(threshold: THRESHOLD)
    @threshold = threshold
    @consecutive_failures = 0
    @just_opened = false
  end

  def open?
    @consecutive_failures >= @threshold
  end

  # Latched true from the moment the breaker opens until the streak resets.
  # The caller reads it exactly once (runner ensure), so no alert is lost when
  # another failure lands after the flip but before the run ends.
  def just_opened?
    @just_opened
  end

  # Feed it an `Extractor::Result` after each extraction attempt. A
  # whole-service failure accumulates; anything else (success, this-post
  # failure, skip) resets the streak.
  def record(result)
    if result.failed? && result.error_kind == :whole_service
      @consecutive_failures += 1
      @just_opened = true if @consecutive_failures == @threshold
    else
      @consecutive_failures = 0
      @just_opened = false
    end

    self
  end
end
