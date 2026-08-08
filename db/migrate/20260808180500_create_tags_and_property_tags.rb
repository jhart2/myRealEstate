class CreateTagsAndPropertyTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.integer :listings_count, null: false, default: 0
      t.timestamps
    end
    add_index :tags, :slug, unique: true

    create_table :property_tags do |t|
      t.references :property, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end
    add_index :property_tags, [ :property_id, :tag_id ], unique: true
  end
end
