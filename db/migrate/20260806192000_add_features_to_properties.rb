class AddFeaturesToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :features, :json, default: [], null: false
  end
end
