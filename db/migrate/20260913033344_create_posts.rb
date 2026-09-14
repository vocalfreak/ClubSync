class CreatePosts < ActiveRecord::Migration[8.0]
  def change
    create_table :posts do |t|
      t.string   :shortcode, null: false
      t.string   :account, null: false
      t.string   :post_type, null: false
      t.text     :caption
      t.string   :source_url, null: false
      t.datetime :posted_at, null: false
      t.jsonb    :raw_payload, null: false
      t.integer  :status, null: false, default: 0
      t.timestamps
    end

    add_index :posts, :shortcode, unique: true
    add_index :posts, :account
    add_index :posts, :status
  end
end
