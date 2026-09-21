require "net/http"
require "uri"
require "json"

class DiscordNotifier
  STAGE_LABELS = {
    "media_processed" => "Media processed",
    "extracted" => "Extracted"
  }.freeze

  def self.post_run_summary(run)
    new(run).post_run_summary
  end

  def self.post_breaker_open
    post_to(ENV["DISCORD_ALERTS_WEBHOOK_URL"], "**ClubSync Alert** — Gemini extraction breaker opened: 5 consecutive whole-service failures. Extraction is skipped for the rest of the run; posts wait at `media_processed` for the next pass.")
  end

  def self.post_to(url, content)
    url = url.to_s.strip
    return if url.empty?

    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(content: content)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.request(request)
  rescue StandardError => e
    Rails.logger.error("DiscordNotifier failed: #{e.class}: #{e.message}")
  end

  def initialize(run)
    @run = run
  end

  def post_run_summary
    self.class.post_to(ENV["DISCORD_LOG_WEBHOOK_URL"], build_message)
  end

  private

  def build_message
    lines = []
    lines << "**ClubSync Run — #{status_label}**"
    lines << "Accounts: #{@run.accounts_processed} processed, #{@run.accounts_failed} failed"
    lines << "Posts scraped: #{@run.posts_scraped}"

    if @run.failed_accounts.present?
      lines << ""
      lines << "**Failed accounts:**"
      @run.failed_accounts.each do |entry|
        lines << "- #{entry["account"]}: #{entry["reason"]}"
      end
    end

    if @run.stage_results.present?
      lines << ""
      lines << "**Stage results:**"
      @run.stage_results.each do |stage, outcomes|
        parts = %w[succeeded failed].filter_map { |outcome| "#{outcomes[outcome]} #{outcome}" if outcomes[outcome].present? }
        lines << "- #{STAGE_LABELS.fetch(stage, stage)}: #{parts.join(', ')}"
      end
    end

    if @run.unexpected_errors&.positive?
      lines << ""
      lines << "Unexpected errors: #{@run.unexpected_errors}"
    end

    if @run.started_at && @run.finished_at
      duration = @run.finished_at - @run.started_at
      lines << ""
      lines << "Duration: #{duration.round(1)}s"
    end

    lines.join("\n")
  end

  def status_label
    case @run.status
    when "finished" then @run.accounts_failed.positive? ? "Finished (#{@run.accounts_failed} failures)" : "Finished"
    when "crashed" then "Crashed"
    else @run.status.capitalize
    end
  end
end
