class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      t.string :name
      t.string :title
      t.text :bio
      t.string :email
      t.string :phone
      t.string :image_url
      t.integer :listings_count
      t.string :sales_volume
      t.boolean :active
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
