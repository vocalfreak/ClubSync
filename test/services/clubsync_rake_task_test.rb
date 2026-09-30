require "test_helper"
require "rake"

class ClubsyncRakeTaskTest < ActiveSupport::TestCase
  test "clubsync:ingest just invokes IngestionRunner.call" do
    Rails.application.load_tasks

    called = false
    original = IngestionRunner.method(:call)
    IngestionRunner.define_singleton_method(:call) { called = true }

    Rake::Task["clubsync:ingest"].invoke

    assert called, "the rake task should delegate to IngestionRunner.call"
  ensure
    IngestionRunner.define_singleton_method(:call, original)
  end

  test "clubsync:extract_one runs the extractor on the matching post" do
    Rails.application.load_tasks

    post = create(:post, :media_processed)
    extracted = false
    original = Extractor.method(:call)
    Extractor.define_singleton_method(:call) do |target, **_kwargs|
      extracted = (target == post)
      Extractor::Result.new(status: :success)
    end

    Rake::Task["clubsync:extract_one"].reenable
    Rake::Task["clubsync:extract_one"].invoke(post.shortcode)

    assert extracted, "the extractor should run on the shortcode's post"
  ensure
    Extractor.define_singleton_method(:call, original)
  end

  test "clubsync:extract_one aborts on a missing shortcode" do
    Rails.application.load_tasks

    Rake::Task["clubsync:extract_one"].reenable
    assert_raises(SystemExit) { Rake::Task["clubsync:extract_one"].invoke }
  end

  test "clubsync:extract_one aborts when no post matches" do
    Rails.application.load_tasks

    Rake::Task["clubsync:extract_one"].reenable
    assert_raises(SystemExit) { Rake::Task["clubsync:extract_one"].invoke("NOSUCHCODE") }
  end

  test "clubsync:rekey_images delegates to ImageRekeyer and honours DRY_RUN" do
    image = create_image("c" * 64)
    seen = []
    stub_rekeyer(seen: seen) do
      with_env("DRY_RUN" => "true") { invoke_rekey_images }
    end

    assert_equal [ true ], seen
    assert_equal "c" * 64, image.reload.b2_key
  end

  test "clubsync:rekey_images exits non-zero when rows failed, so a partial pass isn't read as success" do
    image = create_image("d" * 64)
    failure = ImageRekeyer::Failure.new(image: image, new_key: "#{'d' * 64}.webp", error: "copy failed")

    stub_rekeyer(failures: [ failure ]) do
      assert_raises(SystemExit) { invoke_rekey_images }
    end
  end

  test "clubsync:rekey_images exits zero when nothing failed" do
    stub_rekeyer(rekeyed: [ "a.webp" ]) do
      invoke_rekey_images
    end
  end

  private

  def stub_rekeyer(seen: [], rekeyed: [], failures: [])
    original = ImageRekeyer.method(:call)
    ImageRekeyer.define_singleton_method(:call) do |dry_run: false, logger: nil, **|
      seen << dry_run
      ImageRekeyer::Result.new(
        planned: [], rekeyed: rekeyed, failures: failures, already_keyed: 0, dry_run: dry_run
      )
    end
    yield
  ensure
    ImageRekeyer.define_singleton_method(:call, original)
  end

  def invoke_rekey_images
    Rails.application.load_tasks
    # Every test in this class calls load_tasks, and each call appends another
    # action to the same task object, so invoke would otherwise run the body
    # once per test that has loaded tasks so far. Keep exactly one.
    task = Rake::Task["clubsync:rekey_images"]
    action = task.actions.first
    task.clear_actions
    task.actions << action
    task.reenable
    task.invoke
  end

  def with_env(pairs)
    original = pairs.keys.index_with { |key| ENV[key] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  def create_image(b2_key, content_type: "image/webp")
    Image.create!(post: create(:post), position: 0, b2_key: b2_key, content_type: content_type)
  end
end
