class AddRunMetricsToIngestionRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :ingestion_runs, :stage_results, :jsonb, default: {}
    add_column :ingestion_runs, :unexpected_errors, :integer, null: false, default: 0
    remove_column :ingestion_runs, :stage_failure_counts
  end
end
