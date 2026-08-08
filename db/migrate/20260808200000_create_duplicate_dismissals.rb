class CreateDuplicateDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :duplicate_dismissals do |t|
      t.bigint :property_low_id, null: false
      t.bigint :property_high_id, null: false
      t.string :action, null: false, default: "dismissed"
      t.timestamps
    end

    add_index :duplicate_dismissals, [ :property_low_id, :property_high_id ], unique: true, name: "index_duplicate_dismissals_on_pair"
    add_foreign_key :duplicate_dismissals, :properties, column: :property_low_id
    add_foreign_key :duplicate_dismissals, :properties, column: :property_high_id
  end
end
