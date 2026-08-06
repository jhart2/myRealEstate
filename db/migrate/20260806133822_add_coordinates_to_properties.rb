class AddCoordinatesToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :latitude, :decimal, precision: 10, scale: 7
    add_column :properties, :longitude, :decimal, precision: 10, scale: 7
    add_index :properties, [ :latitude, :longitude ]
  end
end
