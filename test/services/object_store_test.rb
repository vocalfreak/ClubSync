require "test_helper"

class ObjectStoreTest < ActiveSupport::TestCase
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
end
