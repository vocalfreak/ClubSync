class RenameDedupDecisionsToDeduplications < ActiveRecord::Migration[8.0]
  def change
    rename_table :dedup_decisions, :deduplications
    rename_index :deduplications,
                 :index_dedup_decisions_on_post_a_and_post_b,
                 :index_deduplications_on_post_a_and_post_b
  end
end
