# frozen_string_literal: true

class AddLocationRawToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :location_raw, :string
  end
end
