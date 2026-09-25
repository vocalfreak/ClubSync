class AddSeriesToDedupDecisions < ActiveRecord::Migration[8.0]
  def change
    add_column :dedup_decisions, :series, :boolean
  end
end
