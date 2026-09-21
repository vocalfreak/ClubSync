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
end
