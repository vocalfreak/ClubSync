# THROWAWAY design test. Not the public events page — dev only, no auth, no links.
# Delete me and app/views/design/ in one commit.
class Design::GridController < ApplicationController
  MODES = %w[hybrid contain square].freeze

  # The dev .env has no PUBLIC_IMAGE_BASE_URL, so ObjectStore#get_url falls back to a
  # raw private-bucket B2 URL a browser can't load. The Worker serves the dev keys fine
  # (316 of 321 images are <sha256>.webp), so point the img tags straight at it.
  IMAGE_HOST = "https://files.cyberjayahappenings.me".freeze
  SERVABLE_KEY = /\A[a-f0-9]{64}\.webp\z/

  INSTAGRAM_POST = "https://www.instagram.com/p/%s/".freeze

  def index
    @mode = MODES.include?(params[:mode]) ? params[:mode] : "hybrid"
    @modes = MODES
    @cards = cards
    @drawer_events = @cards.map { |card| drawer_event(card) }
  end

  private

  # One card per event group, showing the canonical member (longest caption — the rule
  # from the dedup plan; it is a no-op on this dev data since every real group is a
  # group of one). Every text line is real: no invented titles, dates or venues.
  # Ordered newest-first then by group id, so all three ?mode= pages show the identical
  # cards in the identical order and their cover/contain splits are comparable.
  def cards
    events = Event.joins(:post)
                 .where(posts: { is_event: true, stage: :deduped })
                 .includes(post: :images)
                 .to_a

    events.group_by(&:event_group_id).filter_map do |_group_id, members|
      canonical = members.max_by { |event| [ event.post.caption.to_s.length, -event.post.id ] }
      images = canonical.post.images.to_a

      # The grid gate stays exactly as it was: drop the card unless its FIRST image is
      # servable, so grid membership can't drift when the drawer starts shipping the
      # post's full image list.
      next if images.empty? || !SERVABLE_KEY.match?(images.first.b2_key)

      {
        group_id: canonical.event_group_id,
        image_url: image_url(images.first),
        title: canonical.title,
        date: canonical.starts_on,
        venue: canonical.venue,
        handle: canonical.post.account,
        event_id: canonical.id,
        images: images.filter_map { |image| image_url(image) if SERVABLE_KEY.match?(image.b2_key) },
        starts_time: canonical.starts_time,
        ends_on: canonical.ends_on,
        ends_time: canonical.ends_time,
        caption: canonical.post.caption,
        instagram_url: format(INSTAGRAM_POST, canonical.post.shortcode)
      }
    end.sort_by { |card| [ -(card[:date]&.jd || 0), card[:group_id] || 0 ] }.first(40)
  end

  # What the drawer renders, serialized once into the page. Same events, same order as
  # the grid. Nils are compacted away rather than shipped as null so the drawer can just
  # skip a missing field instead of inventing one.
  def drawer_event(card)
    {
      id: card[:event_id],
      title: card[:title],
      starts_on: card[:date]&.iso8601,
      starts_time: card[:starts_time]&.strftime("%H:%M"),
      ends_on: card[:ends_on]&.iso8601,
      ends_time: card[:ends_time]&.strftime("%H:%M"),
      venue: card[:venue],
      handle: card[:handle],
      caption: card[:caption],
      instagram_url: card[:instagram_url],
      images: card[:images]
    }.compact
  end

  def image_url(image)
    "#{IMAGE_HOST}/#{image.b2_key}"
  end
end
