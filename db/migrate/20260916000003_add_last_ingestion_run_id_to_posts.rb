class AddLastIngestionRunIdToPosts < ActiveRecord::Migration[8.0]
  def change
    add_reference :posts, :last_ingestion_run, foreign_key: { to_table: :ingestion_runs }, null: true
  end
end
