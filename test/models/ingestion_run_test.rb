require "test_helper"

class IngestionRunTest < ActiveSupport::TestCase
  test "defaults to running status" do
    run = IngestionRun.create!(started_at: Time.current)
    assert_equal "running", run.status
  end

  test "status enum values" do
    assert_equal 0, IngestionRun.statuses[:running]
    assert_equal 1, IngestionRun.statuses[:finished]
    assert_equal 2, IngestionRun.statuses[:crashed]
  end

  test "can transition to finished" do
    run = IngestionRun.create!(started_at: Time.current)
    run.update!(status: :finished, finished_at: Time.current)
    assert_equal "finished", run.status
  end

  test "can transition to crashed" do
    run = IngestionRun.create!(started_at: Time.current)
    run.update!(status: :crashed, finished_at: Time.current)
    assert_equal "crashed", run.status
  end

  test "jsonb columns default correctly" do
    run = IngestionRun.create!(started_at: Time.current)
    assert_equal [], run.failed_accounts
    assert_equal({}, run.stage_failure_counts)
  end
end
