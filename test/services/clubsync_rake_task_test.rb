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
    Rails.application.load_tasks
    image = create_image("c" * 64)
    seen = []
    original = ImageRekeyer.method(:call)
    ImageRekeyer.define_singleton_method(:call) do |dry_run: false, logger: nil, **|
      seen << dry_run
      ImageRekeyer::Result.new(planned: [], rekeyed: [], failures: [], already_keyed: 1, dry_run: dry_run)
    end

    with_env("DRY_RUN" => "true") do
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

    assert_equal [ true ], seen
    assert_equal "c" * 64, image.reload.b2_key
  ensure
    ImageRekeyer.define_singleton_method(:call, original)
  end

  private

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
