# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_09_15_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "images", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.integer "position", null: false
    t.string "b2_key", null: false
    t.string "content_type", null: false
    t.integer "width"
    t.integer "height"
    t.integer "byte_size"
    t.string "dhash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id", "position"], name: "index_images_on_post_id_and_position", unique: true
    t.index ["post_id"], name: "index_images_on_post_id"
  end

  create_table "posts", force: :cascade do |t|
    t.string "shortcode", null: false
    t.string "account"
    t.string "post_type"
    t.text "caption"
    t.string "source_url"
    t.datetime "posted_at"
    t.jsonb "raw_payload", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "stage", default: 0, null: false
    t.boolean "is_event"
    t.text "last_error"
    t.datetime "stage_failed_at"
    t.index ["account"], name: "index_posts_on_account"
    t.index ["shortcode"], name: "index_posts_on_shortcode", unique: true
    t.index ["stage"], name: "index_posts_on_stage"
  end

  add_foreign_key "images", "posts"
end
