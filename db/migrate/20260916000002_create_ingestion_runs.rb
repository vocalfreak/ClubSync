class CreateIngestionRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :ingestion_runs do |t|
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer  :status, null: false, default: 0
      t.integer  :accounts_processed, default: 0
      t.integer  :accounts_failed, default: 0
      t.integer  :posts_scraped, default: 0
      t.jsonb    :failed_accounts, default: []
      t.jsonb    :stage_failure_counts, default: {}
      t.text     :notes
      t.timestamps
    end
  end
end
