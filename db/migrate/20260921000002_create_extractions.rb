class CreateExtractions < ActiveRecord::Migration[8.0]
  def change
    create_table :extractions do |t|
      t.references :post, null: false, foreign_key: true
      t.string   :status, null: false
      t.string   :error_kind
      t.text     :error
      t.string   :model
      t.string   :prompt_version
      t.string   :category
      t.float    :category_confidence
      t.jsonb    :raw_response
      t.integer  :input_tokens
      t.integer  :output_tokens
      t.integer  :duration_ms
      t.integer  :image_count
      t.timestamps
    end
  end
end
