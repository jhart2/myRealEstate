class Tag < ApplicationRecord
  has_many :property_tags, dependent: :destroy
  has_many :properties, through: :property_tags

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true

  before_validation :normalize_slug

  def self.slugify(raw)
    raw.to_s.delete_prefix("#").strip.gsub(/[_\s]+/, "").downcase
  end

  def self.display_name(raw)
    text = raw.to_s.delete_prefix("#").strip
    return "" if text.blank?

    if text.match?(/[a-z]/) && text.match?(/[A-Z]/)
      text
    else
      text.split(/[_\s]+/).map(&:capitalize).join
    end
  end

  def refresh_listings_count!
    update_columns(listings_count: property_tags.count, updated_at: Time.current)
  end

  private

  def normalize_slug
    self.slug = self.class.slugify(slug.presence || name)
  end
end
