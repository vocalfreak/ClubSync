# The closed, frozen tag list (2026-09-25) for event posts (plan §3). A
# separate axis from Categories: topical, non-exclusive, zero-or-more,
# informational only — no event?-style mapping, no confidence, no control
# flow. Values are verbatim display labels (Title Case, spaces/slashes intact)
# — see docs/adr/2026-09-25-event-tags-verbatim-labels.md. The parser treats
# out-of-list model output leniently (dropped, never vetoed).
class EventTags
  ALL = %w[
    Academic
    Adventure
    Arts
    Business
    Competitive
    Culture
    Editorial
    Entrepreneur
    Faculty Clubs
    Finance
    Games
    Governance
    Green
    Halls
    Healthcare
    Hobby
    Houses
    Interest/Affinity
    Interprofessional
    Language
    Media
    Mentorship
    Office
    Performance
    Policy
    Politics
    Professional
    Religion
    Residences
    Residential Colleges
    Robotics
    Social Cause
    Social/Recreational
    Sports
    Technology
    Uniform
    Wellness
  ].freeze

  def self.all
    ALL
  end

  def self.include?(tag)
    ALL.include?(tag)
  end
end
