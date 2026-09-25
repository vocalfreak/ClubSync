require "test_helper"

class ConfidenceThresholdTest < ActiveSupport::TestCase
  # Everything here goes through the parser first, so attributes already carry
  # Date objects and clamed confidence — the threshold only adjusts them.
  def thresholded(payload, posted_at: nil)
    result = ExtractionParser.new.parse(payload)
    raise "payload should parse: #{result.errors.inspect}" unless result.valid?

    ConfidenceThreshold.apply(result.attributes, posted_at: posted_at)
  end

  test "drops placeholder and empty venues" do
    [ "TBA", "TBD", "tbd", "tba", "n/a", "na", "unknown", "-", "", "   " ].each do |venue|
      attrs = thresholded(build(:gemini_payload, :reminder).merge("venue" => venue))

      assert_nil attrs[:venue], "venue #{venue.inspect} must be dropped"
      assert_equal 0.0, attrs[:confidence][:venue]
    end
  end

  test "drops too-short and too-long venues" do
    [ "X", "a" * 201 ].each do |venue|
      attrs = thresholded(build(:gemini_payload).merge("venue" => venue))

      assert_nil attrs[:venue], "venue of unusable length must be dropped"
      assert_equal 0.0, attrs[:confidence][:venue]
    end
  end

  test "keeps a real venue with its confidence" do
    payload = build(:gemini_payload)
    payload["venue"] = "Rumah Amanah, Hulu Langat"
    payload["confidence"]["venue"] = 0.8

    attrs = thresholded(payload)

    assert_equal "Rumah Amanah, Hulu Langat", attrs[:venue]
    assert_equal 0.8, attrs[:confidence][:venue]
  end

  test "drops ends entirely when ends_on is before starts_on" do
    payload = build(:gemini_payload).merge(
      "starts_date" => "2026-02-20",
      "ends_date" => "2026-02-18",
      "ends_time" => "18:00"
    )

    attrs = thresholded(payload)

    assert_nil attrs[:ends_date]
    assert_nil attrs[:ends_time]
    assert_equal Date.new(2026, 2, 20), attrs[:starts_date]
  end

  test "keeps ends on or after starts" do
    payload = build(:gemini_payload).merge(
      "starts_date" => "2026-02-20",
      "ends_date" => "2026-02-20"
    )

    assert_equal Date.new(2026, 2, 20), thresholded(payload)[:ends_date]
  end

  test "forces starts_at confidence to zero only outside the sanity window" do
    posted_at = Time.zone.local(2026, 3, 10, 12, 0)
    payload_with = lambda do |starts_date|
      build(:gemini_payload).merge(
        "starts_date" => starts_date,
        "confidence" => { "title" => 0.8, "starts_at" => 0.8, "venue" => 0.8 }
      )
    end

    recent = thresholded(payload_with.call("2026-03-10"))
    assert_equal 0.8, recent[:confidence][:starts_at], "same-day event keeps its confidence"

    inside = thresholded(payload_with.call("2026-03-24"))
    assert_equal 0.8, inside[:confidence][:starts_at]

    too_early = thresholded(payload_with.call("2026-02-20"), posted_at: posted_at)
    assert_equal 0.0, too_early[:confidence][:starts_at], "18 days before posted_at is outside the 14-day window"
    assert_equal Date.new(2026, 2, 20), too_early[:starts_date], "the value is kept, only confidence is zeroed"

    too_late = thresholded(payload_with.call("2027-04-01"), posted_at: posted_at)
    assert_equal 0.0, too_late[:confidence][:starts_at], "beyond 12 months after posted_at"

    boundary = thresholded(payload_with.call("2027-03-10"), posted_at: posted_at)
    assert_equal 0.8, boundary[:confidence][:starts_at], "exactly 12 months out stays inside"
  end
end
