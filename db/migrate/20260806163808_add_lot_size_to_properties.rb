class AddLotSizeToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :lot_sqft, :integer
    add_column :properties, :acres, :decimal, precision: 10, scale: 4
  end
end
