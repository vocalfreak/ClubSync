require "test_helper"

class CosineSimilarityTest < ActiveSupport::TestCase
  test "identical vectors score 1.0" do
    assert_in_delta 1.0, CosineSimilarity.cosine([ 1.0, 0.0 ], [ 1.0, 0.0 ]), 1e-9
  end

  test "orthogonal vectors score 0.0" do
    assert_in_delta 0.0, CosineSimilarity.cosine([ 1.0, 0.0 ], [ 0.0, 1.0 ]), 1e-9
  end

  test "opposite vectors score -1.0" do
    assert_in_delta(-1.0, CosineSimilarity.cosine([ 1.0, 0.0 ], [ -1.0, 0.0 ]), 1e-9)
  end

  test "separates angle from magnitude" do
    assert_in_delta 1.0, CosineSimilarity.cosine([ 0.5, 0.0 ], [ 2.0, 0.0 ]), 1e-9
  end

  test "nil or empty inputs are undefined, not 0.0" do
    assert_nil CosineSimilarity.cosine(nil, [ 1.0 ])
    assert_nil CosineSimilarity.cosine([ 1.0 ], [])
    assert_nil CosineSimilarity.cosine([], [])
  end

  test "length mismatch is undefined" do
    assert_nil CosineSimilarity.cosine([ 1.0 ], [ 1.0, 2.0 ])
  end
end
