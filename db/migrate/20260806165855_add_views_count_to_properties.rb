class AddViewsCountToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :views_count, :integer, null: false, default: 0
  end
end
