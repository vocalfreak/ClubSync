class RelaxWeightedScoreNullOnDedupDecisions < ActiveRecord::Migration[8.0]
  def change
    change_column_null :dedup_decisions, :weighted_score, true
  end
end
