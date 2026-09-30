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
    attr_reader :put_objects, :copy_objects, :reads, :heads

    def initialize(body = "", existing: [])
      @body = body
      @existing = existing
      @put_objects = []
      @copy_objects = []
      @reads = 0
      @heads = 0
    end

    def get_object(bucket:, key:)
      raise ArgumentError, "wrong bucket" unless bucket == "test-bucket"

      @reads += 1
      Struct.new(:body).new(StringIO.new(@body))
    end

    def put_object(**attrs)
      @put_objects << attrs
      nil
    end

    def copy_object(**attrs)
      @copy_objects << attrs
      nil
    end

    def head_object(bucket:, key:)
      raise Aws::S3::Errors::NotFound.new(nil, "no such key") unless @existing.include?(key)

      @heads += 1
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

  test "copy is a server-side bucket-qualified copy that keeps the source metadata" do
    client = FakeS3.new
    store = ObjectStore.new(client: client, bucket: "test-bucket")

    assert_equal "a1b2c3.webp", store.copy("a1b2c3", "a1b2c3.webp")
    assert_equal 1, client.copy_objects.size
    assert_equal(
      { bucket: "test-bucket", key: "a1b2c3.webp", copy_source: "test-bucket/a1b2c3", metadata_directive: "COPY" },
      client.copy_objects.first
    )
  end

  test "copy preserves the source content type by not restating it" do
    client = FakeS3.new
    ObjectStore.new(client: client, bucket: "test-bucket").copy("a1b2c3", "a1b2c3.webp")

    # S3 rejects content_type alongside metadata_directive COPY, so preservation
    # is expressed by the absence of the parameter: the destination inherits
    # image/webp from the source object rather than being told it.
    refute_includes client.copy_objects.first.keys, :content_type
    assert_equal "COPY", client.copy_objects.first[:metadata_directive]
  end

  test "exists? answers from a head rather than a download" do
    client = FakeS3.new(existing: [ "a1b2c3.webp" ])
    store = ObjectStore.new(client: client, bucket: "test-bucket")

    assert store.exists?("a1b2c3.webp")
    assert_equal 0, client.reads, "a head, not a get"
  end

  test "exists? is false, not an exception, when the key is missing" do
    store = ObjectStore.new(client: FakeS3.new, bucket: "test-bucket")

    assert_nothing_raised { assert_equal false, store.exists?("nope.webp") }
  end

  test "exists? is false on either shape of a not-found response" do
    [ Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey ].each do |error|
      client = Class.new do
        define_method(:head_object) { |**| raise error.new(nil, "404") }
      end.new
      store = ObjectStore.new(client: client, bucket: "test-bucket")

      assert_equal false, store.exists?("a1b2c3.webp"), "#{error} should read as absent"
    end
  end
end
