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

ActiveRecord::Schema[8.0].define(version: 2026_09_25_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "handle", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["handle"], name: "index_accounts_on_handle", unique: true
  end

  create_table "deduplications", force: :cascade do |t|
    t.bigint "post_a_id", null: false
    t.bigint "post_b_id", null: false
    t.string "account"
    t.bigint "ingestion_run_id", null: false
    t.integer "hash_distance"
    t.integer "date_distance_days"
    t.float "caption_jaccard"
    t.float "embedding_cosine"
    t.float "weighted_score"
    t.string "outcome", null: false
    t.datetime "decided_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "series"
    t.index ["account"], name: "index_deduplications_on_account"
    t.index ["ingestion_run_id"], name: "index_deduplications_on_ingestion_run_id"
    t.index ["post_a_id", "post_b_id"], name: "index_deduplications_on_post_a_and_post_b", unique: true
  end

  create_table "event_groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "events", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.string "title"
    t.date "starts_on"
    t.time "starts_time"
    t.date "ends_on"
    t.time "ends_time"
    t.string "venue"
    t.string "registration_url"
    t.jsonb "details", default: {}, null: false
    t.float "title_confidence", default: 0.0, null: false
    t.float "starts_at_confidence", default: 0.0, null: false
    t.float "venue_confidence", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "event_group_id"
    t.index ["event_group_id"], name: "index_events_on_event_group_id"
    t.index ["post_id"], name: "index_events_on_post_id", unique: true
    t.index ["starts_on"], name: "index_events_on_starts_on"
    t.check_constraint "ends_on IS NULL OR starts_on IS NOT NULL"
    t.check_constraint "ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on"
  end

  create_table "extractions", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.string "status", null: false
    t.string "error_kind"
    t.text "error"
    t.string "model"
    t.string "prompt_version"
    t.string "category"
    t.float "category_confidence"
    t.jsonb "raw_response"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "duration_ms"
    t.integer "image_count"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "ingestion_run_id"
    t.index ["ingestion_run_id"], name: "index_extractions_on_ingestion_run_id"
    t.index ["post_id"], name: "index_extractions_on_post_id"
  end

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

  create_table "ingestion_runs", force: :cascade do |t|
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.integer "status", default: 0, null: false
    t.integer "accounts_processed", default: 0
    t.integer "accounts_failed", default: 0
    t.integer "posts_scraped", default: 0
    t.jsonb "failed_accounts", default: []
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "stage_results", default: {}
    t.integer "unexpected_errors", default: 0, null: false
    t.jsonb "token_usage", default: {}, null: false
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
    t.bigint "last_ingestion_run_id"
    t.string "category"
    t.jsonb "embedding"
    t.index ["account"], name: "index_posts_on_account"
    t.index ["last_ingestion_run_id"], name: "index_posts_on_last_ingestion_run_id"
    t.index ["shortcode"], name: "index_posts_on_shortcode", unique: true
    t.index ["stage"], name: "index_posts_on_stage"
  end

  add_foreign_key "deduplications", "ingestion_runs"
  add_foreign_key "deduplications", "posts", column: "post_a_id"
  add_foreign_key "deduplications", "posts", column: "post_b_id"
  add_foreign_key "events", "event_groups"
  add_foreign_key "events", "posts"
  add_foreign_key "extractions", "ingestion_runs"
  add_foreign_key "extractions", "posts"
  add_foreign_key "images", "posts"
  add_foreign_key "posts", "ingestion_runs", column: "last_ingestion_run_id"
end
