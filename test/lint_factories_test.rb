require "test_helper"

class LintFactoriesTest < ActiveSupport::TestCase
  test "all factories can be created" do
    assert_nil FactoryBot.lint(traits: true)
  end
end
