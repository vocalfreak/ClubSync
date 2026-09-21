require "test_helper"

class IngestionRunnerTest < ActiveSupport::TestCase
  def setup
    ENV["APIFY_API_TOKEN"] = "apify_api_test_token"
    ENV["DISCORD_LOG_WEBHOOK_URL"] = ""
    ENV["HEALTHCHECKS_PING_URL"] = ""
    Account.delete_all
    Post.delete_all
    IngestionRun.delete_all
  end

  def teardown
    ENV.delete("APIFY_API_TOKEN")
    ENV.delete("DISCORD_LOG_WEBHOOK_URL")
    ENV.delete("HEALTHCHECKS_PING_URL")
  end

  def stub_account_pipeline(success: true, posts_scraped: 1, errors: [])
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |_account, **_kw|
      AccountPipeline::Result.new(success: success, errors: errors, posts_scraped: posts_scraped)
    end
    yield
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  def stub_account_pipeline_raises(error_class, message)
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) { |_account, **_kw| raise error_class, message }
    yield
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  test "creates an IngestionRun record for the run" do
    stub_account_pipeline do
      IngestionRunner.call

      run = IngestionRun.last
      assert_equal "finished", run.status
      refute_nil run.started_at
    end
  end

  test "tallies successful accounts" do
    create(:account, handle: "account1")
    create(:account, handle: "account2")

    stub_account_pipeline(success: true, posts_scraped: 5) do
      IngestionRunner.call

      run = IngestionRun.last
      assert_equal "finished", run.status
      assert_equal 2, run.accounts_processed
      assert_equal 0, run.accounts_failed
      assert_equal 10, run.posts_scraped
    end
  end

  test "tallies failed accounts" do
    create(:account, handle: "failing_account")

    stub_account_pipeline(success: false, errors: [ "Apify timeout" ]) do
      IngestionRunner.call

      run = IngestionRun.last
      assert_equal "finished", run.status
      assert_equal 0, run.accounts_processed
      assert_equal 1, run.accounts_failed
      assert_equal [ { "account" => "failing_account", "reason" => "Apify timeout" } ], run.failed_accounts
    end
  end

  test "handles mixed success and failure" do
    create(:account, handle: "good_account")
    create(:account, handle: "bad_account")

    call_count = 0
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |account, **_kw|
      call_count += 1
      if account.handle == "good_account"
        AccountPipeline::Result.new(success: true, errors: [], posts_scraped: 3)
      else
        AccountPipeline::Result.new(success: false, errors: [ "rate limited" ], posts_scraped: 0)
      end
    end

    IngestionRunner.call

    run = IngestionRun.last
    assert_equal "finished", run.status
    assert_equal 1, run.accounts_processed
    assert_equal 1, run.accounts_failed
    assert_equal 3, run.posts_scraped
    assert_equal 2, call_count
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  test "set stage_failure_counts from posts belonging to the run" do
    create(:account, handle: "account1")

    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |_account, ingestion_run_id: nil|
      Post.create!(shortcode: "ABC123", post_type: "Image", raw_payload: {}, stage: :scraped, last_ingestion_run_id: ingestion_run_id)
      Post.create!(shortcode: "DEF456", post_type: "Image", raw_payload: {}, stage: :media_processed, last_ingestion_run_id: ingestion_run_id)
      AccountPipeline::Result.new(success: true, errors: [], posts_scraped: 2)
    end

    IngestionRunner.call

    run = IngestionRun.last
    assert_equal({ "media_processed" => 1, "scraped" => 1 }, run.stage_failure_counts)
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  test "crashes when AccountPipeline raises an unanticipated exception" do
    create(:account, handle: "buggy_account")

    stub_account_pipeline_raises(RuntimeError, "something went very wrong") do
      IngestionRunner.call

      run = IngestionRun.last
      assert_equal "crashed", run.status
      assert_match(/something went very wrong/, run.notes)
    end
  end

  test "ensure block saves run and calls DiscordNotifier even after crash" do
    create(:account, handle: "buggy_account")

    notifier_called = false
    original_notifier = DiscordNotifier.method(:post_run_summary)
    DiscordNotifier.define_singleton_method(:post_run_summary) { |_run| notifier_called = true }

    stub_account_pipeline_raises(RuntimeError, "crash") do
      IngestionRunner.call
    end

    run = IngestionRun.last
    assert_equal "crashed", run.status
    refute_nil run.finished_at, "ensure always records finished_at, even on crash"
    assert notifier_called, "DiscordNotifier should be called even after crash"
  ensure
    DiscordNotifier.define_singleton_method(:post_run_summary, original_notifier)
  end

  test "ensure always saves the run with finished_at" do
    stub_account_pipeline do
      IngestionRunner.call

      run = IngestionRun.last
      refute_nil run.finished_at
      assert_equal "finished", run.status
    end
  end

  test "ensure calls HealthPing.finish on success" do
    health_ping_finish_called = false
    original = HealthPing.method(:finish)
    HealthPing.define_singleton_method(:finish) { |status| health_ping_finish_called = true }

    stub_account_pipeline do
      IngestionRunner.call
    end

    assert health_ping_finish_called, "HealthPing.finish should be called on success"
  ensure
    HealthPing.define_singleton_method(:finish, original)
  end

  test "ensure does not call HealthPing.finish when crashed" do
    create(:account, handle: "buggy_account")

    health_ping_finish_called = false
    original = HealthPing.method(:finish)
    HealthPing.define_singleton_method(:finish) { |status| health_ping_finish_called = true }

    stub_account_pipeline_raises(RuntimeError, "crash") do
      IngestionRunner.call
    end

    refute health_ping_finish_called, "HealthPing.finish should not be called when crashed"
  ensure
    HealthPing.define_singleton_method(:finish, original)
  end

  test "notifiers must be hermetic: the runner does not rescue them, so a raising notifier aborts the ensure chain" do
    create(:account, handle: "quiet_account")

    original_notifier = DiscordNotifier.method(:post_run_summary)
    DiscordNotifier.define_singleton_method(:post_run_summary) { |_run| raise "webhook down" }

    stub_account_pipeline do
      assert_raises(RuntimeError) { IngestionRunner.call }
    end

    run = IngestionRun.last
    assert_equal "finished", run.status, "the run was saved as finished before the notifier raised"
  ensure
    DiscordNotifier.define_singleton_method(:post_run_summary, original_notifier)
  end
end
