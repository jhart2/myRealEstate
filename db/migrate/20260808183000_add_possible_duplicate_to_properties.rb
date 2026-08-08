class AddPossibleDuplicateToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :possible_duplicate, :boolean, null: false, default: false
    add_index :properties, :possible_duplicate
  end
end
