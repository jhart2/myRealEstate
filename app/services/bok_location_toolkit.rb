# frozen_string_literal: true

# Parse BOK Location blobs and build Location-led geocode queries.
#
# BOK Location is authoritative for pin locality (e.g. "Charlieville Chin Chin Cunupia").
# Mined estate/street lines stay as primary display address.
class BokLocationToolkit
  COUNTRY = "Trinidad and Tobago"

  # Photon / OSM types we treat as real place pins (not shops, churches, etc.).
  PLACE_TYPES = %w[
    street house
    district locality neighbourhood neighborhood suburb
    city town village hamlet county state
  ].freeze

  POI_LABEL_NOISE = /
    \b(
      mart|supermarket|plaza|mall|hotel|guest\s*house|church|bible|
      scout|auto\s*supplies|bureau|authority|park\b|blind\s+welfare|
      open\s+bible|mini\s*mart|gas\s*station|unipet|pennywise
    )\b
  /ix

  SPECIAL_ROAD_EXPANSIONS = {
    "chin chin" => [ "Chin Chin Road", "Chin Chin" ]
  }.freeze

  def self.sanitize(raw)
    value = raw.to_s.strip
    return nil if value.blank? || value.match?(/\A(?:n\/?a|na|none|null|unknown|-)\z/i)

    value.gsub(/\s+/, " ").strip
  end

  def self.tags(location_raw)
    loc = sanitize(location_raw)
    return [] if loc.blank?

    if loc.include?(",")
      return loc.split(/\s*,\s*/).map { |p| sanitize(p) }.compact.uniq
    end

    hits = BokAddressResolver.known_places
      .select { |p| loc.downcase.include?(p) }
      .sort_by { |p| -p.length }

    remaining = loc.downcase
    tags = []
    hits.each do |p|
      next unless remaining.include?(p)

      tags << titleize_tag(p)
      remaining = remaining.sub(p, " ")
    end
    tags.uniq!
    return tags if tags.any?

    [ loc ]
  end

  def self.titleize_tag(value)
    value.to_s.split.map { |w| w.match?(/\A(?:st|rd|dr|ave)\z/i) ? w.capitalize : w.capitalize }.join(" ")
  end

  # Location tags first, then street/estate for display-quality pins.
  def self.geo_queries(location_raw:, address: nil, city: nil, state: nil)
    country = country_for(state)
    tags = tags(location_raw)
    queries = []

    # Prefer special road expansions (Chin Chin → Chin Chin Road) before generic tags.
    tags.each do |tag|
      key = tag.to_s.downcase.strip
      next unless SPECIAL_ROAD_EXPANSIONS.key?(key)

      SPECIAL_ROAD_EXPANSIONS[key].each do |expanded|
        queries << "#{expanded}, #{country}"
        queries << "#{expanded}, #{city}, #{country}" if city.present?
      end
    end

    tags.each do |tag|
      key = tag.to_s.downcase.strip
      next if SPECIAL_ROAD_EXPANSIONS.key?(key)

      queries << "#{tag}, #{city}, #{country}" if city.present? && !tag.casecmp?(city.to_s)
      queries << "#{tag}, #{country}"
    end

    if address.present?
      queries << "#{address}, #{city}, #{country}" if city.present?
      queries << "#{address}, #{country}"
    end

    queries << "#{city}, #{country}" if city.present?
    queries.map { |q| q.to_s.gsub(/\s+/, " ").strip }.reject(&:blank?).uniq
  end

  def self.country_for(state)
    case state.to_s.downcase
    when "barbados" then "Barbados"
    when "tobago" then "Tobago, Trinidad and Tobago"
    else COUNTRY
    end
  end

  def self.place_like_photon?(hit)
    type = hit[:type].to_s
    label = hit[:label].to_s
    return false if label.match?(POI_LABEL_NOISE)
    return true if PLACE_TYPES.include?(type)
    # Unknown type but clean locality-ish name
    !label.match?(POI_LABEL_NOISE)
  end

  def self.default_coords?(lat, lng, epsilon: 0.00025)
    return false if lat.blank? || lng.blank?

    dlat, dlng = BokListingsImporter::DEFAULT_COORDS
    (lat.to_f - dlat).abs < epsilon && (lng.to_f - dlng).abs < epsilon
  end
end
