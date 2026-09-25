require "test_helper"

class CsrwRetaggerTest < ActiveSupport::TestCase
  setup do
    @detector = CsrwRetagger
  end

  test "detector accepts explicit CSRW phrasing" do
    assert @detector.csrw?("Come find our booth during CSRW!")
    assert @detector.csrw?("Club & Society Registration Week briefing")
    assert @detector.csrw?("Club and Society Recruitment Week (CSRW) has wrapped up")
    assert @detector.csrw?("CSRW sign-ups close Sunday")
    assert @detector.csrw?("stand a chance to win blind box goodies in CSRW")
    assert @detector.csrw?("Club & Society Registration Week（CSRW）新学期又开始啦")
  end

  test "detector rejects non-CSRW captions" do
    refute @detector.csrw?("")
    refute @detector.csrw?("Gallery opening downtown at 6pm")
    refute @detector.csrw?("Registration closes Friday for the marathon")
    refute @detector.csrw?("We thank everyone who came to our recital")
    refute @detector.csrw?("sign up at the registration week booth"),
           "bare registration/recruitment week phrasing no longer matches without a club/society"
  end

  test "retag re-categorizes stored CSRW posts and clears their event rows" do
    a = build_event_post(account: "testclub", caption: "Come find our booth during CSRW!",
                         posted_at: Time.utc(2026, 9, 1), starts_on: Date.new(2026, 9, 2))
    a.update!(category: "event")
    group = EventGroup.create!
    a.event.update!(event_group_id: group.id)
    assert a.reload.category == "event"
    assert a.reload.is_event?
    assert a.reload.event.present?

    result = CsrwRetagger.call

    assert_includes result.retagged.map(&:shortcode), a.shortcode
    a.reload
    assert_equal Categories::CSRW, a.category
    refute a.is_event?
    assert_nil a.event
    assert_raises(ActiveRecord::RecordNotFound, "orphaned group-of-one is cleaned up") { group.reload }
    assert_equal 1, result.groups_removed
  end

  test "non-CSRW posts and already-csrw posts are untouched" do
    plain = build_event_post(account: "otherclub", caption: "Studio session sign up tonight",
                             posted_at: Time.utc(2026, 9, 1), starts_on: Date.new(2026, 9, 2))
    plain.update!(category: "event")
    taggable = build_event_post(account: "testclub", caption: "Come find our booth during CSRW!",
                                posted_at: Time.utc(2026, 9, 1), starts_on: Date.new(2026, 9, 2))
    taggable.update!(category: "event")

    result = CsrwRetagger.call

    assert_includes result.retagged.map(&:shortcode), taggable.shortcode
    refute_includes result.retagged.map(&:shortcode), plain.shortcode
    assert_equal "event", plain.reload.category
    assert plain.reload.is_event?
  end

  test "dry-run lists matches without writing anything" do
    post = build_event_post(account: "testclub", caption: "Win goodies at our CSRW booth!",
                            posted_at: Time.utc(2026, 9, 1), starts_on: Date.new(2026, 9, 2))
    post.update!(category: "event")

    result = CsrwRetagger.call(dry_run: true)

    assert_includes result.retagged.map(&:shortcode), post.shortcode
    post.reload
    assert_equal "event", post.category, "dry run must not re-tag"
    assert post.is_event?
    assert post.event.present?
    assert result.summary.include?("dry run")
  end

  test "already-csrw posts are not listed as retagged" do
    post = build_event_post(account: "testclub",
                            posted_at: Time.utc(2026, 9, 1), starts_on: Date.new(2026, 9, 2), caption: "Come find our booth during CSRW!")
    post.update!(category: Categories::CSRW, is_event: false)

    result = CsrwRetagger.call

    assert result.retagged.empty?, result.retagged.inspect
    assert_equal Categories::CSRW, post.reload.category
  end
end
