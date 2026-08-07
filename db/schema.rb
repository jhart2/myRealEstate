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

ActiveRecord::Schema[8.1].define(version: 2026_08_07_031352) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agents", force: :cascade do |t|
    t.boolean "active", default: true
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "image_url"
    t.integer "listings_count", default: 0
    t.string "name"
    t.string "phone"
    t.string "sales_volume"
    t.boolean "show_on_homepage", default: false, null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.integer "years_experience"
    t.index ["user_id"], name: "index_agents_on_user_id"
  end

  create_table "favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "property_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["property_id"], name: "index_favorites_on_property_id"
    t.index ["user_id", "property_id"], name: "index_favorites_on_user_id_and_property_id", unique: true
    t.index ["user_id"], name: "index_favorites_on_user_id"
  end

  create_table "inquiries", force: :cascade do |t|
    t.integer "agent_id"
    t.datetime "created_at", null: false
    t.string "email"
    t.text "message"
    t.string "name"
    t.string "phone"
    t.integer "property_id"
    t.string "status", default: "new"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["agent_id"], name: "index_inquiries_on_agent_id"
    t.index ["property_id"], name: "index_inquiries_on_property_id"
    t.index ["user_id"], name: "index_inquiries_on_user_id"
  end

  create_table "properties", force: :cascade do |t|
    t.decimal "acres", precision: 10, scale: 4
    t.string "address"
    t.integer "agent_id", null: false
    t.decimal "baths", precision: 3, scale: 1
    t.integer "beds"
    t.string "bok_id"
    t.string "city"
    t.boolean "copy_needs_review", default: false, null: false
    t.json "copy_review_notes", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "featured", default: false
    t.json "features", default: [], null: false
    t.string "image_url"
    t.json "image_urls", default: [], null: false
    t.decimal "latitude"
    t.decimal "longitude"
    t.integer "lot_sqft"
    t.bigint "price_cents"
    t.string "price_label"
    t.string "property_type"
    t.string "slug"
    t.string "source_url"
    t.integer "sqft"
    t.string "state"
    t.string "status", default: "active"
    t.string "tag"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "views_count", default: 0, null: false
    t.string "zip"
    t.index ["agent_id"], name: "index_properties_on_agent_id"
    t.index ["bok_id"], name: "index_properties_on_bok_id", unique: true
    t.index ["copy_needs_review"], name: "index_properties_on_copy_needs_review"
    t.index ["latitude", "longitude"], name: "index_properties_on_latitude_and_longitude"
    t.index ["slug"], name: "index_properties_on_slug", unique: true
    t.index ["source_url"], name: "index_properties_on_source_url", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_subscriptions_on_email", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agents", "users"
  add_foreign_key "favorites", "properties"
  add_foreign_key "favorites", "users"
  add_foreign_key "inquiries", "agents"
  add_foreign_key "inquiries", "properties"
  add_foreign_key "inquiries", "users"
  add_foreign_key "properties", "agents"
  add_foreign_key "sessions", "users"
end
