require "test_helper"

class ExtractionParserTest < ActiveSupport::TestCase
  def parse(payload)
    ExtractionParser.new.parse(payload)
  end

  test "parses a valid event payload into canonical attributes" do
    result = parse(build(:gemini_payload))

    assert result.valid?
    assert_empty result.errors

    attrs = result.attributes
    assert_equal "event", attrs[:category]
    assert_equal true, attrs[:is_event]
    assert_kind_of Date, attrs[:starts_date]
    assert_equal "20:15", attrs[:starts_time]
    assert_equal "22:00", attrs[:ends_time]
    assert_equal true, attrs[:checks]["has_date"]
    assert_equal %i[starts_at title venue], attrs[:confidence].keys.sort
    assert attrs[:confidence].values.all? { |value| value.is_a?(Float) }
  end

  test "parses a valid non-event payload with is_event false and no date" do
    result = parse(build(:gemini_payload, :fundraising))

    assert result.valid?
    assert_equal "fundraising", result.attributes[:category]
    refute result.attributes[:is_event]
    assert_nil result.attributes[:starts_date]
    assert_nil result.attributes[:venue]
  end

  test "every category in the list parses as valid" do
    Categories.all.each do |category|
      trait = category.to_sym
      result = parse(build(:gemini_payload, trait))
      assert result.valid?, "category #{category} produced errors: #{result.errors.inspect}"
      assert_equal category, result.attributes[:category]
    end
  end

  test "a payload with every optional field null is still valid" do
    payload = build(:gemini_payload).merge(
      "title" => nil,
      "starts_date" => nil,
      "starts_time" => nil,
      "ends_date" => nil,
      "ends_time" => nil,
      "venue" => nil,
      "registration_url" => nil,
      "registration_via" => nil,
      "members_only" => nil,
      "online_only" => nil,
      "notes" => nil
    )

    result = parse(payload)

    assert result.valid?, result.errors.inspect
    assert_equal true, result.attributes[:is_event]
  end

  test "Clamps confidence numbers into 0..1" do
    payload = build(:gemini_payload).merge(
      "category_confidence" => 1.7,
      "confidence" => { "title" => -0.5, "starts_at" => 0.3, "venue" => 1.4 }
    )

    attrs = parse(payload).attributes

    assert_equal 1.0, attrs[:category_confidence]
    assert_equal 0.0, attrs[:confidence][:title]
    assert_equal 0.3, attrs[:confidence][:starts_at]
    assert_equal 1.0, attrs[:confidence][:venue]
  end

  test "a non-object response is fatal" do
    result = parse("just a string")

    assert result.fatal?
    refute result.valid?
    assert_nil result.attributes
  end

  test "fails on a category outside the closed list" do
    result = parse(build(:gemini_payload, :bad_category))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("category") }
  end

  test "fails on a semantically impossible date" do
    result = parse(build(:gemini_payload, :impossible_date))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("starts_date") && error.include?("not a real calendar date") }
  end

  test "fails on a malformed time" do
    result = parse(build(:gemini_payload, :bad_time))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("starts_time") }
  end

  test "fails on non-numeric confidence" do
    result = parse(build(:gemini_payload, :bad_confidence))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("confidence.title") }
  end

  test "fails when a required key is missing" do
    result = parse(build(:gemini_payload).except("notes"))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("notes") }
  end

  test "fails when a nullable field has the wrong type" do
    result = parse(build(:gemini_payload).merge("title" => 42))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("title") }
  end

  test "fails when registration_via is outside its enum" do
    result = parse(build(:gemini_payload).merge("registration_via" => "carrier_pigeon"))

    refute result.valid?
    assert result.errors.any? { |error| error.include?("registration_via") }
  end
end
