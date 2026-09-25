require "test_helper"

class GeminiQuotaAlertTest < ActiveSupport::TestCase
  def setup
    ENV.delete("GEMINI_DAILY_REQUESTS")
    ENV.delete("GEMINI_DAILY_TOKENS")
  end

  def teardown
    ENV.delete("GEMINI_DAILY_REQUESTS")
    ENV.delete("GEMINI_DAILY_TOKENS")
  end

  def usage(requests:, tokens:)
    { "requests" => requests, "input_tokens" => tokens, "output_tokens" => 0, "total_tokens" => tokens }
  end

  test "does nothing when no caps are configured" do
    assert_nothing_raised { GeminiQuotaAlert.call(usage(requests: 500, tokens: 1_000_000)) }
  end

  test "posts an alert when daily requests cross 80% of the configured cap" do
    ENV["GEMINI_DAILY_REQUESTS"] = "200"
    posted = nil
    original = DiscordNotifier.method(:post_quota_alert)
    DiscordNotifier.define_singleton_method(:post_quota_alert) { |breaches| posted = breaches }

    GeminiQuotaAlert.call(usage(requests: 161, tokens: 0))

    assert_equal 1, posted.length
    assert_equal "requests", posted.first[:metric]
    assert_equal 161, posted.first[:current]
    assert_equal 200, posted.first[:cap]
  ensure
    DiscordNotifier.define_singleton_method(:post_quota_alert, original)
  end

  test "does not alert below 80% of the cap" do
    ENV["GEMINI_DAILY_REQUESTS"] = "200"
    posted = false
    original = DiscordNotifier.method(:post_quota_alert)
    DiscordNotifier.define_singleton_method(:post_quota_alert) { |_breaches| posted = true }

    GeminiQuotaAlert.call(usage(requests: 159, tokens: 0))

    refute posted
  ensure
    DiscordNotifier.define_singleton_method(:post_quota_alert, original)
  end

  test "alerts on the daily token cap too" do
    ENV["GEMINI_DAILY_TOKENS"] = "1000"
    posted = nil
    original = DiscordNotifier.method(:post_quota_alert)
    DiscordNotifier.define_singleton_method(:post_quota_alert) { |breaches| posted = breaches }

    GeminiQuotaAlert.call(usage(requests: 0, tokens: 801))

    assert_equal "total_tokens", posted.first[:metric]
    assert_equal 801, posted.first[:current]
  ensure
    DiscordNotifier.define_singleton_method(:post_quota_alert, original)
  end

  test "is hermetic: a raising notifier is logged, never raised" do
    ENV["GEMINI_DAILY_REQUESTS"] = "200"
    original = DiscordNotifier.method(:post_quota_alert)
    DiscordNotifier.define_singleton_method(:post_quota_alert) { |_breaches| raise "webhook down" }

    assert_nothing_raised { GeminiQuotaAlert.call(usage(requests: 200, tokens: 0)) }
  ensure
    DiscordNotifier.define_singleton_method(:post_quota_alert, original)
  end
end
