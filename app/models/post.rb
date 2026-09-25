class Post < ApplicationRecord
  enum :stage, { scraped: 0, media_processed: 1, extracted: 2, deduped: 3 }, default: :scraped

  has_many :images, -> { order(:position) }, dependent: :destroy
  has_one :event
  has_many :extractions

  # Dead-lettered: the tail of the 3 most recent extractions rows are all
  # `failed` with `error_kind: "this_post"`. Any `succeeded` row or any
  # `whole_service` row in that tail resets it — one Gemini-wide outage can't
  # dead-letter a post, and a success clears the slate.
  scope :dead_lettered, lambda {
    where(<<~SQL.squish)
      id IN (
        SELECT post_id FROM (
          SELECT post_id, status, error_kind,
                 ROW_NUMBER() OVER (PARTITION BY post_id ORDER BY id DESC) AS rn
          FROM extractions
        ) tail
        WHERE tail.rn <= 3
        GROUP BY post_id
        HAVING count(*) = 3
           AND bool_and(tail.status = 'failed' AND tail.error_kind = 'this_post')
      )
    SQL
  }

  def dead_lettered?
    tail = extractions.order(id: :desc).limit(3)
    tail.size == 3 && tail.all? { |row| row.failed? && row.error_kind == "this_post" }
  end
end
