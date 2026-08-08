class PropertyTag < ApplicationRecord
  belongs_to :property
  belongs_to :tag, counter_cache: :listings_count

  validates :property_id, uniqueness: { scope: :tag_id }
end
