require "test_helper"

class CategoriesTest < ActiveSupport::TestCase
  test "the list is frozen and closed" do
    assert Categories.all.frozen?
    assert_equal(
      %w[event reminder fundraising recruitment recap merch_or_sales deadline teaser general_announcement other],
      Categories.all
    )
    Categories.all.each { |category| assert Categories.include?(category) }
  end

  test "event? is true only for event" do
    assert Categories.event?("event")
    Categories.all.each do |category|
      refute Categories.event?(category), "#{category} must not be an event" unless category == "event"
    end
  end

  test "include? rejects unknown categories" do
    refute Categories.include?("mystery_category")
  end
end
