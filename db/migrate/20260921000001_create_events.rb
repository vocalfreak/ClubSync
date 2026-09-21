class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :events do |t|
      t.references :post, null: false, foreign_key: true, index: { unique: true }
      t.string   :title
      t.date     :starts_on
      t.time     :starts_time
      t.date     :ends_on
      t.time     :ends_time
      t.string   :venue
      t.string   :registration_url
      t.jsonb    :details, null: false, default: {}
      t.float    :title_confidence,     null: false, default: 0.0
      t.float    :starts_at_confidence, null: false, default: 0.0
      t.float    :venue_confidence,     null: false, default: 0.0
      t.timestamps

      t.check_constraint "ends_on IS NULL OR starts_on IS NOT NULL"
      t.check_constraint "ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on"
    end

    add_index :events, :starts_on
  end
end
