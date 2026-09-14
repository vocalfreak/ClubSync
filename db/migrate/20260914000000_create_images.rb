class CreateImages < ActiveRecord::Migration[8.0]
  def change
    create_table :images do |t|
      t.references :post, null: false, foreign_key: true
      t.integer :position, null: false
      t.string  :b2_key, null: false
      t.string  :content_type, null: false
      t.integer :width
      t.integer :height
      t.integer :byte_size
      t.string  :dhash
      t.timestamps
    end

    add_index :images, [ :post_id, :position ], unique: true
  end
end
