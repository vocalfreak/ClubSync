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
    attr_reader :put_objects

    def initialize(body = "")
      @body = body
      @put_objects = []
    end

    def get_object(bucket:, key:)
      raise ArgumentError, "wrong bucket" unless bucket == "test-bucket"

      Struct.new(:body).new(StringIO.new(@body))
    end

    def put_object(**attrs)
      @put_objects << attrs
      nil
    end
  end

  test "put keys the object by content hash so identical bytes are one object" do
    bytes = "webp-bytes".b
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    key = store.put(bytes, content_type: "image/webp")

    assert_equal "#{Digest::SHA256.hexdigest(bytes)}.webp", key
  end

  test "put derives the extension from content_type" do
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert store.put("a".b, content_type: "image/jpeg").end_with?(".jpg")
    assert store.put("b".b, content_type: "image/png").end_with?(".png")
  end

  test "put falls back to .bin for an unfamiliar content type rather than failing the upload" do
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert store.put("a".b, content_type: "application/octet-stream").end_with?(".bin")
  end

  test "put sends the bytes and content type through to the client" do
    bytes = "png-bytes".b
    client = FakeS3.new
    store = ObjectStore.new(client: client, bucket: "test-bucket")

    store.put(bytes, content_type: "image/png")

    assert_equal 1, client.put_objects.size
    assert_equal bytes, client.put_objects.first[:body]
    assert_equal "image/png", client.put_objects.first[:content_type]
    assert_equal "test-bucket", client.put_objects.first[:bucket]
    assert_equal store.put(bytes, content_type: "image/png"), client.put_objects.first[:key]
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
