require "test_helper"

class ExtractionPromptTest < ActiveSupport::TestCase
  test "the hand-bumped version is v3 (recap-wins + QR precision landed 2026-09-24)" do
    assert_equal "v3", ExtractionPrompt::VERSION
  end

  test "generation_config requests JSON with the frozen schema, checks first" do
    config = ExtractionPrompt.generation_config

    assert_equal "application/json", config["responseMimeType"]
    assert_equal 0, config["temperature"]
    assert_equal({ "thinkingLevel" => "low" }, config["thinkingConfig"])
    assert_extraction_schema(config["responseSchema"])
  end

  test "the schema enum is exactly the closed category list" do
    schema = ExtractionPrompt.generation_config["responseSchema"]

    assert_equal Categories.all, schema["properties"]["category"]["enum"]
  end

  test "every required schema key is declared" do
    schema = ExtractionPrompt.generation_config["responseSchema"]

    schema["required"].each { |key| assert_includes schema["properties"].keys, key }
  end

  test "system instruction covers the event test and precedence rule" do
    assert_includes ExtractionPrompt::SYSTEM_INSTRUCTION, "PRECEDENCE"
    assert_includes ExtractionPrompt::SYSTEM_INSTRUCTION, "reminder"
    assert_includes ExtractionPrompt::SYSTEM_INSTRUCTION, "YYYY-MM-DD"
  end

  test "v3 bakes in recap-wins precedence and the QR-visuals-only precision rule" do
    instruction = ExtractionPrompt::SYSTEM_INSTRUCTION
    assert_includes instruction, "RECAP WINS"
    assert_includes instruction, "restating the past date/venue"
    assert_includes instruction, "Huge thanks to everyone who came to our charity night last Friday!\" => recap"
    assert_includes instruction, "qr_code_seen is true ONLY when a clearly visible QR code is actually printed in one of the images"
  end

  test "user_text embeds the caption and the local posted date" do
    text = ExtractionPrompt.user_text(
      caption: "Riddim night at Memory",
      posted_at: Time.zone.parse("2026-09-11T12:00:00Z"),
      timezone: "Asia/Kuala_Lumpur"
    )

    assert_includes text, "Riddim night at Memory"
    assert_includes text, "2026-09-11"
    assert_includes text, "Asia/Kuala_Lumpur"
  end

  private

  def assert_extraction_schema(schema)
    assert_equal "object", schema["type"]
    assert_equal ExtractionPrompt::SCHEMA_PROPERTY_ORDER, schema["propertyOrdering"]
    assert_equal "checks", schema["propertyOrdering"].first
    assert_equal schema["propertyOrdering"], schema["required"]

    schema["properties"].each do |key, definition|
      assert_includes definition.keys, "type"
      assert_includes %w[string number boolean object], definition["type"], "key #{key} has a type"
    end
  end
end
