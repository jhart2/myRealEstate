class AddImageUrlsToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :image_urls, :json, default: [], null: false
  end
end
