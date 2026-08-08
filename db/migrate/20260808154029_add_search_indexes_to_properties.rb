# frozen_string_literal: true

class AddSearchIndexesToProperties < ActiveRecord::Migration[8.1]
  # Composite indexes aligned with Property.search:
  # every query starts with status: "active", then filters/sorts by tag, price,
  # map bounds, property_type, beds, featured, and created_at.
  def change
    add_index :properties, [ :status, :tag, :price_cents ],
              name: "index_properties_on_status_tag_price"

    add_index :properties, [ :status, :latitude, :longitude ],
              name: "index_properties_on_status_lat_lng"

    add_index :properties, [ :status, :featured, :created_at ],
              name: "index_properties_on_status_featured_created"

    add_index :properties, [ :status, :property_type, :price_cents ],
              name: "index_properties_on_status_type_price"

    add_index :properties, [ :status, :beds ],
              name: "index_properties_on_status_beds"

    add_index :properties, [ :status, :created_at ],
              name: "index_properties_on_status_created_at"
  end
end
