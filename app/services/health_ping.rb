require "net/http"
require "uri"

class HealthPing
  def self.start
    ping("start")
  end

  def self.fail
    ping("fail")
  end

  def self.finish(status)
    ping(nil) unless status.to_s == "crashed"
  end

  def self.ping(suffix)
    url = ENV["HEALTHCHECKS_PING_URL"].to_s.strip
    return if url.empty?

    ping_url = suffix ? "#{url}/#{suffix}" : url
    uri = URI.parse(ping_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.get(uri.request_uri)
  rescue StandardError => e
    Rails.logger.error("HealthPing failed: #{e.class}: #{e.message}")
  end
end
