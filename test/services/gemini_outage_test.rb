require "test_helper"

class GeminiOutageTest < ActiveSupport::TestCase
  def extractor_result(status, error_kind = nil)
    Extractor::Result.new(status: status, error_kind: error_kind, error: error_kind ? "boom" : nil)
  end

  test "starts inactive" do
    outage = GeminiOutage.new

    refute outage.active?
    assert_equal 0, outage.consecutive_failures
  end

  test "becomes active after 5 consecutive whole-service failures" do
    outage = GeminiOutage.new

    4.times { outage.record(extractor_result(:failed, :whole_service)) }
    refute outage.active?
    refute outage.just_started?

    outage.record(extractor_result(:failed, :whole_service))
    assert outage.active?
    assert outage.just_started?, "the 5th failure is the call that activates the outage"
  end

  test "just_started stays latched until the streak resets" do
    outage = GeminiOutage.new
    5.times { outage.record(extractor_result(:failed, :whole_service)) }
    assert outage.just_started?

    outage.record(extractor_result(:failed, :whole_service))
    assert outage.just_started?, "once active, further failures keep the latch set"

    outage.record(extractor_result(:success))
    refute outage.just_started?, "a reset clears the latch"
  end

  test "resets on a success" do
    outage = GeminiOutage.new
    4.times { outage.record(extractor_result(:failed, :whole_service)) }
    outage.record(extractor_result(:success))

    refute outage.active?
    assert_equal 0, outage.consecutive_failures
  end

  test "resets on a this-post failure" do
    outage = GeminiOutage.new
    4.times { outage.record(extractor_result(:failed, :whole_service)) }
    outage.record(extractor_result(:failed, :this_post))

    refute outage.active?
    assert_equal 0, outage.consecutive_failures
  end

  test "skipped outcomes also reset the streak" do
    outage = GeminiOutage.new
    4.times { outage.record(extractor_result(:failed, :whole_service)) }
    outage.record(extractor_result(:skipped))

    refute outage.active?
    assert_equal 0, outage.consecutive_failures
  end
end
