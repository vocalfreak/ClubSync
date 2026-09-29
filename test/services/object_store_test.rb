require "test_helper"

class ObjectStoreTest < ActiveSupport::TestCase
  PUBLIC_IMAGE_BASE_URL = "PUBLIC_IMAGE_BASE_URL"
  B2_BUCKET = "B2_BUCKET"
  B2_ENDPOINT = "B2_ENDPOINT"

  def setup
    @original_public_image_base_url = ENV.delete(PUBLIC_IMAGE_BASE_URL)
    ENV[B2_ENDPOINT] = "https://s3.us-west-004.backblazeb2.com"
    ENV[B2_BUCKET] = "env-bucket"
  end

  def teardown
    ENV.delete(PUBLIC_IMAGE_BASE_URL)
    ENV[B2_ENDPOINT] = "https://s3.us-west-004.backblazeb2.com"
    ENV[B2_BUCKET] = "env-bucket"
    ENV[PUBLIC_IMAGE_BASE_URL] = @original_public_image_base_url
  end

  class FakeS3
    def initialize(body = "")
      @body = body
    end

    def get_object(bucket:, key:)
      raise ArgumentError, "wrong bucket" unless bucket == "test-bucket"

      Struct.new(:body).new(StringIO.new(@body))
    end
  end

  test "get returns the object bytes as a string" do
    bytes = "\x89PNG\r\n".b
    store = ObjectStore.new(client: FakeS3.new(bytes), bucket: "test-bucket")

    assert_equal bytes, store.get("a1b2c3")
  end

  test "get_url falls back to the path-style B2 url when no public image host is set" do
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert_equal "https://s3.us-west-004.backblazeb2.com/test-bucket/a1b2c3", store.get_url("a1b2c3")
  end

  test "get_url prefers the public image host so repeat views are served from the edge" do
    ENV[PUBLIC_IMAGE_BASE_URL] = "https://files.cyberjayahappenings.me"
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert_equal "https://files.cyberjayahappenings.me/a1b2c3", store.get_url("a1b2c3")
  end

  test "get_url tolerates a trailing slash on the public image host" do
    ENV[PUBLIC_IMAGE_BASE_URL] = "https://files.cyberjayahappenings.me/"
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert_equal "https://files.cyberjayahappenings.me/a1b2c3", store.get_url("a1b2c3")
  end

  test "get_url uses the injected bucket rather than the environment" do
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert_includes store.get_url("a1b2c3"), "/test-bucket/"
    refute_includes store.get_url("a1b2c3"), "/env-bucket/"
  end
end
