class ChangePropertiesBathsToDecimal < ActiveRecord::Migration[8.1]
  def change
    change_column :properties, :baths, :decimal, precision: 3, scale: 1
  end
end
