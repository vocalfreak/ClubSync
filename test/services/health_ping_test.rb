require "test_helper"

class HealthPingTest < ActiveSupport::TestCase
  def setup
    ENV["HEALTHCHECKS_PING_URL"] = "https://hc-ping.com/test-uuid"
  end

  def teardown
    ENV.delete("HEALTHCHECKS_PING_URL")
  end

  def stub_http_get
    requested_path = nil
    original_get = Net::HTTP.instance_method(:get)
    Net::HTTP.define_method(:get) do |path_or_uri, *_args|
      requested_path = path_or_uri.to_s
      Net::HTTPOK.new("1.1", 200, "OK")
    end

    yield
    requested_path
  ensure
    Net::HTTP.define_method(:get, original_get)
  end

  test "start pings the /start suffix" do
    path = stub_http_get { HealthPing.start }
    assert path.end_with?("/start")
  end

  test "fail pings the /fail suffix" do
    path = stub_http_get { HealthPing.fail }
    assert path.end_with?("/fail")
  end

  test "finish pings the bare URL on success" do
    path = stub_http_get { HealthPing.finish("finished") }
    assert_equal "/test-uuid", path
  end

  test "finish does not ping when status is crashed" do
    original_get = Net::HTTP.instance_method(:get)
    called = false
    Net::HTTP.define_method(:get) { |*_args| called = true; Net::HTTPOK.new("1.1", 200, "OK") }

    HealthPing.finish("crashed")

    refute called, "should not ping when status is crashed"
  ensure
    Net::HTTP.define_method(:get, original_get)
  end

  test "does nothing when HEALTHCHECKS_PING_URL is blank" do
    ENV["HEALTHCHECKS_PING_URL"] = ""

    original_get = Net::HTTP.instance_method(:get)
    called = false
    Net::HTTP.define_method(:get) { |*_args| called = true; Net::HTTPOK.new("1.1", 200, "OK") }

    HealthPing.start

    refute called, "should not make HTTP request when URL is blank"
  ensure
    Net::HTTP.define_method(:get, original_get)
  end

  test "does nothing when HEALTHCHECKS_PING_URL is not set" do
    ENV.delete("HEALTHCHECKS_PING_URL")

    original_get = Net::HTTP.instance_method(:get)
    called = false
    Net::HTTP.define_method(:get) { |*_args| called = true; Net::HTTPOK.new("1.1", 200, "OK") }

    HealthPing.start

    refute called, "should not make HTTP request when URL is not set"
  ensure
    Net::HTTP.define_method(:get, original_get)
  end

  test "swallows network errors without raising" do
    original_get = Net::HTTP.instance_method(:get)
    Net::HTTP.define_method(:get) { |*_args| raise "connection refused" }

    assert_nothing_raised do
      HealthPing.start
    end
  ensure
    Net::HTTP.define_method(:get, original_get)
  end
end
