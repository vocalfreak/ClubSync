class IngestionRun < ApplicationRecord
  has_many :extractions
  has_many :deduplications

  enum :status, { running: 0, finished: 1, crashed: 2 }, default: :running
end
