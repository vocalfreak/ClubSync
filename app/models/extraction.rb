class Extraction < ApplicationRecord
  belongs_to :post
  belongs_to :ingestion_run, optional: true

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end
end
