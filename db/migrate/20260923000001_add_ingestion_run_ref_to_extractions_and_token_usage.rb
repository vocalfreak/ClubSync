class AddIngestionRunRefToExtractionsAndTokenUsage < ActiveRecord::Migration[8.0]
  def change
    add_reference :extractions, :ingestion_run, null: true, foreign_key: true
    add_column :ingestion_runs, :token_usage, :jsonb, null: false, default: {}
  end
end
