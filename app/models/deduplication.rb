class Deduplication < ApplicationRecord
  belongs_to :post_a, class_name: "Post"
  belongs_to :post_b, class_name: "Post"
  belongs_to :ingestion_run

  validates :post_a_id, :post_b_id, presence: true
  validates :outcome, inclusion: { in: %w[merged separate] }

  def merged?
    outcome == "merged"
  end
end
