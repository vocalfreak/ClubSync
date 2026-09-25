class CreateDedupDecisions < ActiveRecord::Migration[8.0]
  def change
    create_table :dedup_decisions do |t|
      t.bigint   :post_a_id, null: false
      t.bigint   :post_b_id, null: false
      t.string   :account
      t.bigint   :ingestion_run_id, null: false
      t.integer  :hash_distance
      t.integer  :date_distance_days
      t.float    :caption_jaccard
      t.float    :embedding_cosine
      t.float    :weighted_score, null: false
      t.string   :outcome, null: false
      t.datetime :decided_at, null: false
      t.timestamps
    end

    add_index :dedup_decisions, [ :post_a_id, :post_b_id ], unique: true, name: "index_dedup_decisions_on_post_a_and_post_b"
    add_index :dedup_decisions, :account
    add_index :dedup_decisions, :ingestion_run_id

    add_foreign_key :dedup_decisions, :posts, column: :post_a_id
    add_foreign_key :dedup_decisions, :posts, column: :post_b_id
    add_foreign_key :dedup_decisions, :ingestion_runs
  end
end
