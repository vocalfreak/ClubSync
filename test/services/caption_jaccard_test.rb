require "test_helper"

class CaptionJaccardTest < ActiveSupport::TestCase
  test "identical token sets score 1.0" do
    assert_in_delta 1.0, CaptionJaccard.similarity("Riddim night at Memory", "riddim night at memory"), 1e-9
  end

  test "disjoint captions score 0.0" do
    assert_in_delta 0.0, CaptionJaccard.similarity("Riddim night", "Gallery opening"), 1e-9
  end

  test "partial overlap scores the Jaccard ratio" do
    assert_in_delta 2.0 / 4.0, CaptionJaccard.similarity("red blue green", "red blue yellow"), 1e-9
  end

  test "is case- and punctuation-insensitive" do
    a = CaptionJaccard.similarity("Riddim Night!", "riddim night")
    assert_in_delta 1.0, a, 1e-9
  end

  test "a nil or blank caption yields nil (undefined channel), not 0.0" do
    assert_nil CaptionJaccard.similarity(nil, "something")
    assert_nil CaptionJaccard.similarity("something", "")
    assert_nil CaptionJaccard.similarity(nil, nil)
  end
end
