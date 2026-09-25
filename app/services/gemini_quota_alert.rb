# Soft-cap alert (plan gap §4): once per run, if today's Gemini usage has
# crossed 80% of an env-configured daily cap (`GEMINI_DAILY_REQUESTS` and/or
# `GEMINI_DAILY_TOKENS`), post one alert to #clubsync-alerts. Inert while a cap
# is unset — the quota's real number is only settled on the AI Studio
# dashboard, so nothing is hardcoded here. Hermetic like every notifier: never
# raises, logs its own failures.
class GeminiQuotaAlert
  SOFT_CAP_RATIO = 0.8

  def self.call(usage = GeminiUsage.today)
    new(usage).call
  end

  def initialize(usage)
    @usage = usage
  end

  def call
    breaches = compute_breaches
    DiscordNotifier.post_quota_alert(breaches) if breaches.any?
  rescue StandardError => e
    Rails.logger.error("GeminiQuotaAlert failed: #{e.class}: #{e.message}")
  end

  private

  def compute_breaches
    [
      breach("requests", "GEMINI_DAILY_REQUESTS"),
      breach("total_tokens", "GEMINI_DAILY_TOKENS")
    ].compact
  end

  def breach(metric, env_key)
    cap = ENV[env_key].to_s.strip
    return nil if cap.empty?

    cap = Integer(cap, exception: false)
    return nil if cap.nil? || cap <= 0

    current = @usage.fetch(metric, 0)
    return nil if current < (cap * SOFT_CAP_RATIO)

    { metric: metric, current: current, cap: cap, threshold: cap * SOFT_CAP_RATIO }
  end
end
