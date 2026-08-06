class CreateProperties < ActiveRecord::Migration[8.1]
  def change
    create_table :properties do |t|
      t.string :title
      t.string :slug
      t.string :tag
      t.string :property_type
      t.string :status
      t.string :address
      t.string :city
      t.string :state
      t.string :zip
      t.integer :price_cents
      t.string :price_label
      t.integer :beds
      t.integer :baths
      t.integer :sqft
      t.text :description
      t.string :image_url
      t.boolean :featured
      t.references :agent, null: false, foreign_key: true

      t.timestamps
    end
    add_index :properties, :slug, unique: true
  end
end
