require "test_helper"

class GeminiBreakerTest < ActiveSupport::TestCase
  def extractor_result(status, error_kind = nil)
    Extractor::Result.new(status: status, error_kind: error_kind, error: error_kind ? "boom" : nil)
  end

  test "starts closed" do
    breaker = GeminiBreaker.new

    refute breaker.open?
    assert_equal 0, breaker.consecutive_failures
  end

  test "opens after 5 consecutive whole-service failures" do
    breaker = GeminiBreaker.new

    4.times { breaker.record(extractor_result(:failed, :whole_service)) }
    refute breaker.open?
    refute breaker.just_opened?

    breaker.record(extractor_result(:failed, :whole_service))
    assert breaker.open?
    assert breaker.just_opened?, "the 5th failure is the call that flips it open"
  end

  test "just_opened stays latched until the streak resets" do
    breaker = GeminiBreaker.new
    5.times { breaker.record(extractor_result(:failed, :whole_service)) }
    assert breaker.just_opened?

    breaker.record(extractor_result(:failed, :whole_service))
    assert breaker.just_opened?, "once open, further failures keep the latch set"

    breaker.record(extractor_result(:success))
    refute breaker.just_opened?, "a reset clears the latch"
  end

  test "resets on a success" do
    breaker = GeminiBreaker.new
    4.times { breaker.record(extractor_result(:failed, :whole_service)) }
    breaker.record(extractor_result(:success))

    refute breaker.open?
    assert_equal 0, breaker.consecutive_failures
  end

  test "resets on a this-post failure" do
    breaker = GeminiBreaker.new
    4.times { breaker.record(extractor_result(:failed, :whole_service)) }
    breaker.record(extractor_result(:failed, :this_post))

    refute breaker.open?
    assert_equal 0, breaker.consecutive_failures
  end

  test "skipped outcomes also reset the streak" do
    breaker = GeminiBreaker.new
    4.times { breaker.record(extractor_result(:failed, :whole_service)) }
    breaker.record(extractor_result(:skipped))

    refute breaker.open?
    assert_equal 0, breaker.consecutive_failures
  end
end
