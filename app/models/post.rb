class Post < ApplicationRecord
  enum :stage, { scraped: 0, media_processed: 1, deduped: 2, extracted: 3 }, default: :scraped

  has_many :images, -> { order(:position) }, dependent: :destroy
  has_one :event
  has_many :extractions
end
