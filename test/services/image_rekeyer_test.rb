require "test_helper"

class ImageRekeyerTest < ActiveSupport::TestCase
  # Stands in for the S3 client ObjectStore wraps, so the real ObjectStore#copy
  # and #exists? run underneath. Copies land in @existing, `head_missing`
  # simulates a copy that claims success without producing anything, and every
  # other mutating call B2 offers is trapped -- a future edit that starts
  # deleting shows up here as a failure rather than as dev's data loss.
  class FakeS3Client
    attr_reader :copies, :heads

    def initialize(head_missing: [], fail_on: [])
      @existing = Set.new
      @head_missing = head_missing.to_set
      @fail_on = fail_on.to_set
      @copies = []
      @heads = []
    end

    def copy_object(copy_source:, key:, **)
      raise Aws::S3::Errors::ServiceError.new(nil, "copy failed") if @fail_on.include?(copy_source.split("/").last)

      @copies << [ copy_source, key ]
      @existing << key
      nil
    end

    def head_object(key:, **)
      @heads << key
      raise Aws::S3::Errors::NotFound.new(nil, "no such key") if @head_missing.include?(key) || !@existing.include?(key)

      nil
    end

    # Only reachable through ObjectStore#put, used by the test that cross-checks
    # a rekeyed key against a freshly computed one.
    def put_object(**attrs)
      @puts ||= []
      @puts << attrs
      nil
    end

    def method_missing(name, ...)
      raise "the rekeyer must never call the client for #{name}"
    end

    def respond_to_missing?(...)
      true
    end
  end

  HEX_A = "a" * 64
  HEX_B = "b" * 64
  BUCKET = "test-bucket"

  def setup
    @client = FakeS3Client.new
    @log = []
  end

  test "copies an extensionless object to the extension key and repoints the row" do
    image = create_image(b2_key: HEX_A)

    result = rekey

    assert_equal [ [ "#{BUCKET}/#{HEX_A}", "#{HEX_A}.webp" ] ], @client.copies
    assert_equal [ "#{HEX_A}.webp" ], @client.heads
    assert_equal "#{HEX_A}.webp", image.reload.b2_key
    assert_equal 1, result.rekeyed.size
    assert_empty result.failures
  end

  test "a rekeyed key is the key a fresh upload of the same bytes would have produced" do
    bytes = "webp-bytes".b
    uploaded = ObjectStore.new(client: FakeS3Client.new, bucket: BUCKET).put(bytes, content_type: "image/webp")
    image = create_image(b2_key: Digest::SHA256.hexdigest(bytes))

    rekey

    assert_equal uploaded, image.reload.b2_key
  end

  test "skips a row whose key already carries an extension" do
    already = create_image(b2_key: "#{HEX_A}.webp")

    result = rekey

    assert_empty @client.copies
    assert_equal 1, result.already_keyed
    assert_equal 0, result.planned.size
    assert_equal "#{HEX_A}.webp", already.reload.b2_key
  end

  test "rekeying is idempotent, so a rerun of a finished pass does nothing" do
    create_image(b2_key: HEX_A)
    create_image(b2_key: HEX_B)

    first = rekey
    second = rekey

    assert_equal 2, first.rekeyed.size
    assert_equal 2, @client.copies.size, "the rerun should not copy anything again"
    assert_equal 0, second.planned.size
    assert_equal 2, second.already_keyed
    assert_equal 0, second.rekeyed.size
  end

  test "leaves the row alone and reports the failure when the copy raises" do
    image = create_image(b2_key: HEX_A)
    client = FakeS3Client.new(fail_on: [ HEX_A ])

    result = ImageRekeyer.call(object_store: store_for(client), logger: ->(line) { @log << line })

    assert_equal HEX_A, image.reload.b2_key
    assert_empty client.heads, "no point spending a head on a copy that failed"
    assert_equal 1, result.failures.size
    assert_match "copy failed", result.failures.first.to_s
    assert_equal 0, result.rekeyed.size
  end

  test "does not repoint the row when the copy is not visible to a head_object" do
    image = create_image(b2_key: HEX_A)
    client = FakeS3Client.new(head_missing: [ "#{HEX_A}.webp" ])

    result = ImageRekeyer.call(object_store: store_for(client), logger: ->(line) { @log << line })

    assert_equal HEX_A, image.reload.b2_key
    assert_equal 1, result.failures.size
    assert_match "head_object found nothing", result.failures.first.to_s
    assert_equal 0, result.rekeyed.size
  end

  test "a failing row does not stop the ones after it" do
    broken = create_image(b2_key: HEX_A)
    healthy = create_image(b2_key: HEX_B)
    client = FakeS3Client.new(fail_on: [ HEX_A ])

    result = ImageRekeyer.call(object_store: store_for(client), logger: ->(line) { @log << line })

    assert_equal HEX_A, broken.reload.b2_key
    assert_equal "#{HEX_B}.webp", healthy.reload.b2_key
    assert_equal 1, result.rekeyed.size
    assert_equal 1, result.failures.size
  end

  test "reports an unrecognised content type instead of guessing an extension" do
    image = create_image(b2_key: HEX_A, content_type: "application/octet-stream")

    result = rekey

    assert_equal HEX_A, image.reload.b2_key
    assert_empty @client.copies
    assert_equal 0, result.planned.size
    assert_match "unrecognised content_type", result.failures.first.to_s
  end

  test "a dry run plans the work but touches neither B2 nor the database" do
    image = create_image(b2_key: HEX_A)

    result = rekey(dry_run: true)

    assert_empty @client.copies
    assert_empty @client.heads
    assert_equal HEX_A, image.reload.b2_key
    assert_equal [ [ image, "#{HEX_A}.webp" ] ], result.planned
    assert_empty result.rekeyed
    assert_match "dry run", result.summary
  end

  test "a dry run reports no rows as processed" do
    create_image(b2_key: HEX_A, count: 50)

    rekey(dry_run: true)

    assert_equal 12, @log.size, "count, 10 sample rows, the truncated tail"
    refute @log.any? { |line| line.start_with?("processed") }, "nothing was processed, so nothing should claim to be"
  end

  test "logs progress every 50 rows and names the totals" do
    create_image(b2_key: HEX_A, count: 50)

    result = rekey

    assert_equal "processed 50/50 · 0 failed", @log.last
    assert_equal "  ...and 40 more", @log[-2]
    assert_equal 13, @log.size, "count, 10 sample rows, the truncated tail, one progress line"
    assert_equal 50, result.rekeyed.size
  end

  test "announces the plan before touching anything" do
    create_image(b2_key: HEX_A)
    create_image(b2_key: HEX_B)

    rekey

    assert_equal "2 rows to rekey", @log.first
    assert_match "-> #{HEX_A}.webp", @log[1]
    assert_match "-> #{HEX_B}.webp", @log[2]
  end

  test "summary reads as a finished pass on a rerun" do
    create_image(b2_key: HEX_A)
    rekey
    result = rekey

    assert_equal "0 rows to rekey · rekeyed 0 · 1 already keyed (rerun)", result.summary
  end

  test "summary reports a partial pass" do
    create_image(b2_key: HEX_A)
    create_image(b2_key: HEX_B)
    ImageRekeyer.call(object_store: store_for(FakeS3Client.new(fail_on: [ HEX_B ])), logger: ->(line) { @log << line })

    result = ImageRekeyer.call(object_store: store_for(@client), logger: ->(line) { @log << line })

    assert_equal "1 row to rekey · rekeyed 1 · 1 already keyed (rerun)", result.summary
  end

  private

  def rekey(dry_run: false)
    ImageRekeyer.call(dry_run: dry_run, object_store: store_for(@client), logger: ->(line) { @log << line })
  end

  def store_for(client)
    ObjectStore.new(client: client, bucket: BUCKET)
  end

  def create_image(b2_key:, content_type: "image/webp", count: 1)
    post = create(:post)
    Array.new(count) do |i|
      Image.create!(
        post: post,
        position: i,
        b2_key: count == 1 ? b2_key : "#{b2_key}#{i}",
        content_type: content_type
      )
    end.first
  end
end
