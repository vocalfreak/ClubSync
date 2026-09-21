require "test_helper"

class DiscordNotifierTest < ActiveSupport::TestCase
  def setup
    ENV["DISCORD_LOG_WEBHOOK_URL"] = "https://discord.com/api/webhooks/test-id/test-token"
  end

  def teardown
    ENV.delete("DISCORD_LOG_WEBHOOK_URL")
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

  test "includes failed accounts and stage breakdown in the message" do
    run = create(:ingestion_run, :finished,
                 accounts_failed: 1,
                 failed_accounts: [ { "account" => "baddie", "reason" => "Apify timeout" } ],
                 stage_failure_counts: { "scraped" => 2 })

    result = stub_net_http { DiscordNotifier.post_run_summary(run) }

    payload = JSON.parse(result[:body])
    assert_includes payload["content"], "1 failed"
    assert_includes payload["content"], "baddie"
    assert_includes payload["content"], "Apify timeout"
    assert_includes payload["content"], "scraped"
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
end
