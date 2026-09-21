class IngestionRun < ApplicationRecord
  enum :status, { running: 0, finished: 1, crashed: 2 }, default: :running
end
