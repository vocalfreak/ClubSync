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

  def stub_account_pipeline(success: true, posts_scraped: 1, errors: [], stage_results: {}, unexpected_errors: 0)
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |_account, **_kw|
      AccountPipeline::Result.new(
        success: success, errors: errors, posts_scraped: posts_scraped,
        stage_results: stage_results, unexpected_errors: unexpected_errors
      )
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
        AccountPipeline::Result.new(success: true, errors: [], posts_scraped: 3, stage_results: {}, unexpected_errors: 0)
      else
        AccountPipeline::Result.new(success: false, errors: [ "rate limited" ], posts_scraped: 0, stage_results: {}, unexpected_errors: 0)
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

  test "sums stage_results and unexpected_errors across accounts onto the run" do
    create(:account, handle: "account1")
    create(:account, handle: "account2")

    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |account, **_kw|
      if account.handle == "account1"
        AccountPipeline::Result.new(
          success: true, errors: [], posts_scraped: 3,
          stage_results: { "media_processed" => { "succeeded" => 2, "failed" => 1 } },
          unexpected_errors: 1
        )
      else
        AccountPipeline::Result.new(
          success: true, errors: [], posts_scraped: 1,
          stage_results: { "media_processed" => { "succeeded" => 1 }, "extracted" => { "failed" => 1 } },
          unexpected_errors: 2
        )
      end
    end

    IngestionRunner.call

    run = IngestionRun.last
    assert_equal(
      { "media_processed" => { "succeeded" => 3, "failed" => 1 }, "extracted" => { "failed" => 1 } },
      run.stage_results
    )
    assert_equal 3, run.unexpected_errors
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  test "creates one GeminiOutage and passes it to every AccountPipeline call" do
    create(:account, handle: "account1")
    create(:account, handle: "account2")

    outages_seen = []
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |_account, **_kw|
      outages_seen << _kw[:outage]
      AccountPipeline::Result.new(success: true, errors: [], posts_scraped: 1, stage_results: {}, unexpected_errors: 0)
    end

    IngestionRunner.call

    assert_equal 2, outages_seen.size
    assert_kind_of GeminiOutage, outages_seen.first
    assert_equal 1, outages_seen.uniq.size, "one outage tracker instance per run"
  ensure
    AccountPipeline.define_singleton_method(:call, original)
  end

  test "posts the outage alert only when the run ends with the outage active" do
    create(:account, handle: "account1")
    create(:account, handle: "account2")

    alert_called = false
    original_alert = DiscordNotifier.method(:post_gemini_outage)
    DiscordNotifier.define_singleton_method(:post_gemini_outage) { alert_called = true }

    calls = 0
    original = AccountPipeline.method(:call)
    AccountPipeline.define_singleton_method(:call) do |_account, **_kw|
      calls += 1
      outage = _kw[:outage]
      failures = calls <= 2 ? 1 : 5
      failures.times { outage.record(Extractor::Result.new(status: :failed, error_kind: :whole_service, error: "quota")) }
      AccountPipeline::Result.new(success: true, errors: [], posts_scraped: 1, stage_results: {}, unexpected_errors: 0)
    end

    IngestionRunner.call
    refute alert_called, "2 consecutive failures across the first run do not activate the outage"

    IngestionRunner.call
    assert alert_called, "an active outage at run end posts the one-shot alert"
  ensure
    AccountPipeline.define_singleton_method(:call, original)
    DiscordNotifier.define_singleton_method(:post_gemini_outage, original_alert)
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

  test "persists the run's token usage for the Discord summary" do
    stub_account_pipeline do
      IngestionRunner.call

      run = IngestionRun.last
      assert_equal(
        { "requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0 },
        run.token_usage
      )
    end
  end

  test "invokes the Gemini soft-cap alert at the end of every run" do
    called = false
    original = GeminiQuotaAlert.method(:call)
    GeminiQuotaAlert.define_singleton_method(:call) { |*_args| called = true }

    stub_account_pipeline do
      IngestionRunner.call
    end

    assert called
  ensure
    GeminiQuotaAlert.define_singleton_method(:call, original)
  end

  test "a token-usage read failure never aborts the notifier chain" do
    notifier_called = false
    original_usage = GeminiUsage.method(:for_run)
    GeminiUsage.define_singleton_method(:for_run) { |_run| raise "usage backend down" }
    original_notifier = DiscordNotifier.method(:post_run_summary)
    DiscordNotifier.define_singleton_method(:post_run_summary) { |_run| notifier_called = true }

    stub_account_pipeline do
      IngestionRunner.call
    end

    assert notifier_called, "the summary still posts when usage accounting fails"
    assert_equal({}, IngestionRun.last.token_usage, "the failed read leaves the default jsonb behind")
  ensure
    GeminiUsage.define_singleton_method(:for_run, original_usage)
    DiscordNotifier.define_singleton_method(:post_run_summary, original_notifier)
  end

  test "folds the end-of-run dedup pass into the run record" do
    original = Deduplicator.method(:call)
    Deduplicator.define_singleton_method(:call) do |**_kw|
      Deduplicator::Result.new(
        stage_results: { "deduped" => { "merged" => 2, "succeeded" => 2 } },
        unexpected_errors: 1,
        note: "embed failed: boom"
      )
    end

    stub_account_pipeline do
      IngestionRunner.call
    end

    run = IngestionRun.last
    assert_equal "finished", run.status, "a reported dedup hiccup never crashes the run"
    assert_equal 2, run.stage_results["deduped"]["merged"]
    assert_equal 2, run.stage_results["deduped"]["succeeded"]
    assert_equal 1, run.unexpected_errors
    assert_match(/Deduplicator: embed failed: boom/, run.notes)
  ensure
    Deduplicator.define_singleton_method(:call, original)
  end

  test "runs a real dedup pass over scraped posts before finishing the run" do
    shortcode_a = Faker::Alphanumeric.unique.alphanumeric(number: 11)
    a = Post.create!(
      shortcode: shortcode_a, account: "club-wired", post_type: "Image", caption: "Riddim night",
      source_url: "https://x/#{shortcode_a}", posted_at: Time.utc(2026, 8, 1),
      raw_payload: { "type" => "Image" }, stage: :extracted, is_event: true
    )
    Event.create!(post: a, title: "night", starts_on: Date.new(2026, 10, 1))
    Image.create!(post: a, position: 0, b2_key: "k-a", content_type: "image/webp", dhash: "0" * 16)
    b = Post.create!(
      shortcode: Faker::Alphanumeric.unique.alphanumeric(number: 11), account: "club-wired", post_type: "Image",
      caption: "Riddim night", source_url: "https://x/#{shortcode_a}", posted_at: Time.utc(2026, 8, 19),
      raw_payload: { "type" => "Image" }, stage: :extracted, is_event: true
    )
    Event.create!(post: b, title: "night", starts_on: Date.new(2026, 10, 1))
    Image.create!(post: b, position: 0, b2_key: "k-b", content_type: "image/webp", dhash: "0" * 16)

    stub_account_pipeline do
      IngestionRunner.call
    end

    run = IngestionRun.last
    assert_equal 1, run.stage_results["deduped"]["merged"]
    assert_equal 1, run.stage_results["deduped"]["succeeded"]
    assert_equal "finished", run.status
    assert a.reload.deduped?
    assert_equal a.event.reload.event_group_id, b.event.reload.event_group_id
  end
end
