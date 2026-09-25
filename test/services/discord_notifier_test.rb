require "test_helper"

class DiscordNotifierTest < ActiveSupport::TestCase
  def setup
    ENV["DISCORD_LOG_WEBHOOK_URL"] = "https://discord.com/api/webhooks/test-id/test-token"
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = ""
  end

  def teardown
    ENV.delete("DISCORD_LOG_WEBHOOK_URL")
    ENV.delete("DISCORD_ALERT_WEBHOOK_URL")
  end

  def stub_net_http
    posted_body = nil
    posted_uri = nil
    original_request = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) do |request|
      posted_uri = request.uri.to_s
      posted_body = request.body
      Net::HTTPOK.new("1.1", 200, "OK")
    end

    yield
    { body: posted_body, uri: posted_uri }
  ensure
    Net::HTTP.define_method(:request, original_request)
  end

  test "posts a JSON summary to the webhook URL" do
    run = create(:ingestion_run, :finished)

    result = stub_net_http { DiscordNotifier.post_run_summary(run) }

    assert_equal "https://discord.com/api/webhooks/test-id/test-token", result[:uri]
    refute_nil result[:body]
    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "ClubSync Run"
    assert_includes payload["content"], "5 processed"
    assert_includes payload["content"], "15"
  end

  test "includes failed accounts, stage results and unexpected errors in the message" do
    run = create(:ingestion_run, :finished,
                 accounts_failed: 1,
                 failed_accounts: [ { "account" => "baddie", "reason" => "Apify timeout" } ],
                 stage_results: { "media_processed" => { "succeeded" => 8, "failed" => 1 }, "extracted" => { "succeeded" => 9 } },
                 unexpected_errors: 2)

    result = stub_net_http { DiscordNotifier.post_run_summary(run) }

    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "1 failed"
    assert_includes payload["content"], "baddie"
    assert_includes payload["content"], "Apify timeout"
    assert_includes payload["content"], "Media processed: 8 succeeded, 1 failed"
    assert_includes payload["content"], "Extracted: 9 succeeded"
    assert_includes payload["content"], "Unexpected errors: 2"
  end

  test "lists dead-lettered posts and Gemini token usage in the summary" do
    run = create(:ingestion_run, :finished,
                 stage_results: { "extracted" => { "succeeded" => 5, "failed" => 2, "dead_lettered" => 3 } },
                 token_usage: { "requests" => 10, "input_tokens" => 1200, "output_tokens" => 300, "total_tokens" => 1500 })

    result = stub_net_http { DiscordNotifier.post_run_summary(run) }

    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "Extracted: 5 succeeded, 2 failed, 3 dead-lettered"
    assert_includes payload["content"], "Gemini usage: 10 requests, 1200 input + 300 output tokens"
  end

  test "renders the dedup stage with merged pairs in the summary" do
    run = create(:ingestion_run, :finished,
                 stage_results: { "deduped" => { "succeeded" => 3, "merged" => 2, "failed" => 1 } })

    result = stub_net_http { DiscordNotifier.post_run_summary(run) }

    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "Dedup: 3 succeeded, 2 merged, 1 failed"
  end

  test "does nothing when DISCORD_LOG_WEBHOOK_URL is blank" do
    ENV["DISCORD_LOG_WEBHOOK_URL"] = ""
    run = create(:ingestion_run, :finished)

    assert_nothing_raised { DiscordNotifier.post_run_summary(run) }
  end

  test "does nothing when DISCORD_LOG_WEBHOOK_URL is not set" do
    ENV.delete("DISCORD_LOG_WEBHOOK_URL")
    run = create(:ingestion_run, :finished)

    assert_nothing_raised { DiscordNotifier.post_run_summary(run) }
  end

  test "swallows network errors without raising" do
    run = create(:ingestion_run, :finished)

    original_request = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) { |_request| raise "connection refused" }

    assert_nothing_raised do
      DiscordNotifier.post_run_summary(run)
    end
  ensure
    Net::HTTP.define_method(:request, original_request)
  end

  test "post_gemini_outage posts a one-shot alert to the alerts webhook" do
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = "https://discord.com/api/webhooks/alerts-id/alerts-token"

    result = stub_net_http { DiscordNotifier.post_gemini_outage }

    assert_equal "https://discord.com/api/webhooks/alerts-id/alerts-token", result[:uri]
    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "Gemini extraction outage"
  end

  test "post_gemini_outage does nothing when the alerts webhook is blank" do
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = ""

    assert_nothing_raised { DiscordNotifier.post_gemini_outage }
  end

  test "post_gemini_outage swallows network errors without raising" do
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = "https://discord.com/api/webhooks/alerts-id/alerts-token"

    original_request = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) { |_request| raise "connection refused" }

    assert_nothing_raised { DiscordNotifier.post_gemini_outage }
  ensure
    Net::HTTP.define_method(:request, original_request)
  end

  test "post_quota_alert posts a one-shot alert to the alerts webhook" do
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = "https://discord.com/api/webhooks/alerts-id/alerts-token"
    breaches = [ { metric: "requests", current: 160, cap: 200, threshold: 160 } ]

    result = stub_net_http { DiscordNotifier.post_quota_alert(breaches) }

    assert_equal "https://discord.com/api/webhooks/alerts-id/alerts-token", result[:uri]
    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "160 of 200 requests"
  end

  test "post_quota_alert does nothing without breaches" do
    ENV["DISCORD_ALERT_WEBHOOK_URL"] = "https://discord.com/api/webhooks/alerts-id/alerts-token"

    original_request = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) { |_request| flunk "must not post without breaches" }

    assert_nothing_raised { DiscordNotifier.post_quota_alert([]) }
  ensure
    Net::HTTP.define_method(:request, original_request)
  end
end
