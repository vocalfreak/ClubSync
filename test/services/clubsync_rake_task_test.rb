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
end
