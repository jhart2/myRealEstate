class AddBokFieldsToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :bok_id, :string
    add_column :properties, :source_url, :string
    add_index :properties, :bok_id, unique: true
    add_index :properties, :source_url, unique: true
  end
end
