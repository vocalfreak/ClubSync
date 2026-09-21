require "net/http"
require "uri"
require "json"

class DiscordNotifier
  def self.post_run_summary(run)
    new(run).post_run_summary
  end

  def initialize(run)
    @run = run
  end

  def post_run_summary
    url = ENV["DISCORD_LOG_WEBHOOK_URL"].to_s.strip
    return if url.empty?

    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(content: build_message)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.request(request)
  rescue StandardError => e
    Rails.logger.error("DiscordNotifier failed: #{e.class}: #{e.message}")
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

    if @run.stage_failure_counts.present?
      lines << ""
      lines << "**Stage breakdown:**"
      @run.stage_failure_counts.each do |stage, count|
        lines << "- #{stage}: #{count}"
      end
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
