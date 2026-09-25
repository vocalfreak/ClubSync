# One-off re-tagger for posts stored before the CSRW category existed (or
# that Gemini tagged `event`/`recap`/`other` instead). CSRW ("Club & Society
# Registration Week") is the annual university-wide recruitment week: booth
# invites, "during CSRW" promos, sign-ups and post-week recaps are all
# `club_and_society_registration_week` — technically attendable, but never
# surfaced as an event card.
# Detection is lexical/fuzzy over the stored caption — never a Gemini re-call
# (plan §6: re-derivation without re-calling Gemini).
class CsrwRetagger
  # Tightened 2026-09-24 (decided-pending-build): the bare
  # registration/recruitment-week marker is dropped — any club-society
  # phrasing or an explicit CSRW mention still matches, but a loose
  # "recruitment week" with no club context no longer does.
  MARKERS = [
    /\bCSRW\b/i,
    /club.{0,40}society.{0,40}(?:registration|recruitment).{0,10}week/i
  ].freeze

  def self.csrw?(caption)
    caption = caption.to_s
    return false if caption.blank?

    MARKERS.any? { |marker| marker.match?(caption) }
  end

  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
  end

  def call
    retagged = []
    Post.where.not(caption: nil).order(:account, :shortcode).each do |post|
      next unless self.class.csrw?(post.caption)
      next if post.category == Categories::CSRW

      retagged << post
      next if @dry_run

      post.update!(category: Categories::CSRW, is_event: false)
      post.event&.destroy!
    end

    groups_removed = 0
    unless @dry_run
      orphan_groups = EventGroup
                      .where.not(id: Event.select(:event_group_id).where.not(event_group_id: nil))
                      .to_a
      groups_removed = orphan_groups.size
      EventGroup.where(id: orphan_groups.map(&:id)).delete_all
    end

    Result.new(retagged: retagged, groups_removed: groups_removed, dry_run: @dry_run)
  end

  Result = Struct.new(:retagged, :groups_removed, :dry_run, keyword_init: true) do
    def summary
      out = "retagged #{retagged.size} post#{"s" unless retagged.size == 1}"
      out += " · removed #{groups_removed} empty event_groups" if groups_removed.positive?
      out += " (dry run — nothing written)" if dry_run
      out
    end
  end
end
