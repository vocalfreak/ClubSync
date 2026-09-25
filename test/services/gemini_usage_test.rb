require "test_helper"

class GeminiUsageTest < ActiveSupport::TestCase
  test "for_run sums requests and tokens from that run's extraction rows only" do
    run = create(:ingestion_run)
    post = create(:post)
    create(:extraction, post: post, ingestion_run_id: run.id, input_tokens: 100, output_tokens: 10)
    create(:extraction, post: post, ingestion_run_id: run.id, input_tokens: 50, output_tokens: 5)
    create(:extraction, :failed, post: post, ingestion_run_id: run.id, input_tokens: nil, output_tokens: nil)

    other_run = create(:ingestion_run)
    create(:extraction, post: post, ingestion_run_id: other_run.id, input_tokens: 999, output_tokens: 999)

    usage = GeminiUsage.for_run(run)

    assert_equal 3, usage["requests"], "every outcome row counts as one request"
    assert_equal 150, usage["input_tokens"]
    assert_equal 15, usage["output_tokens"]
    assert_equal 165, usage["total_tokens"]
  end

  test "for_run with no rows yields zeros" do
    run = create(:ingestion_run)

    assert_equal(
      { "requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0 },
      GeminiUsage.for_run(run)
    )
  end

  test "today scopes to rows created on the current calendar day" do
    post = create(:post)
    create(:extraction, post: post, input_tokens: 40, output_tokens: 4)
    old = create(:extraction, post: post, input_tokens: 1, output_tokens: 1)
    old.update_columns(created_at: 2.days.ago)

    usage = GeminiUsage.today

    assert_equal 1, usage["requests"]
    assert_equal 40, usage["input_tokens"]
    assert_equal 4, usage["output_tokens"]
  end
end
