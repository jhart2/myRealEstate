# Refines Property lat/lng when we have a street-like address but only a
# community / city-centroid pin (CITY_COORDS / DEFAULT_COORDS).
#
# Does not invent street-level precision for city-only stubs ("Chaguanas").
# Prefer Google Geocoding (cached); skip weak APPROXIMATE locality hits.
class PropertyStreetGeocoder
  class Error < StandardError; end

  EPSILON = 0.00025 # ~25–30m — matches seed/BOK city centroid dumps
  MIN_CONFIDENCE = 45
  CACHE_TTL = 30.days

  Result = Struct.new(:latitude, :longitude, :confidence, :location_type, :source, :query, keyword_init: true)

  def self.city_level_coords?(latitude, longitude)
    new.city_level_coords?(latitude, longitude)
  end

  def self.street_worthy?(address, city = nil)
    new.street_worthy?(address, city)
  end

  def self.needs_refine?(attrs)
    new.needs_refine?(attrs)
  end

  def self.refine(attrs, google: GoogleAddressClient.new)
    new(google: google).refine(attrs)
  end

  def initialize(google: GoogleAddressClient.new)
    @google = google
  end

  def city_level_coords?(latitude, longitude)
    return true if latitude.blank? || longitude.blank?

    lat = latitude.to_f
    lng = longitude.to_f
    default = BokListingsImporter::DEFAULT_COORDS
    return true if near?(lat, lng, default[0], default[1])

    BokListingsImporter::CITY_COORDS.any? do |_name, (clat, clng)|
      near?(lat, lng, clat, clng)
    end
  end

  def street_worthy?(address, city = nil)
    quality = BokAddressResolver.address_quality(address, city)
    return true if quality >= 3
    return false if address.blank?
    return false if city.present? && address.to_s.casecmp?(city.to_s)
    return false if BokAddressResolver.marketing_text?(address)

    address.to_s.match?(BokAddressResolver::STREET_PATTERN)
  end

  def needs_refine?(attrs)
    attrs = stringify(attrs)
    return false unless street_worthy?(attrs["address"] || attrs[:address], attrs["city"] || attrs[:city])
    return false unless city_level_coords?(attrs["latitude"] || attrs[:latitude], attrs["longitude"] || attrs[:longitude])

    true
  end

  # Returns Result with refined coords, or nil when Google is unavailable / too coarse.
  def refine(attrs)
    attrs = stringify(attrs)
    return nil unless needs_refine?(attrs)
    return nil unless @google.configured?

    query = build_query(attrs)
    resolved = cached_resolve(query, attrs["state"] || attrs[:state])
    return nil unless usable?(resolved)

    Result.new(
      latitude: resolved.latitude,
      longitude: resolved.longitude,
      confidence: resolved.confidence,
      location_type: resolved.location_type,
      source: resolved.source,
      query: query
    )
  end

  private

  def near?(lat, lng, target_lat, target_lng)
    (lat - target_lat).abs < EPSILON && (lng - target_lng).abs < EPSILON
  end

  def stringify(attrs)
    case attrs
    when Hash then attrs.transform_keys(&:to_s)
    when ListingAddressBrain::Result, BokAddressResolver::Result
      {
        "address" => attrs.address,
        "city" => attrs.city,
        "state" => attrs.state,
        "latitude" => attrs.latitude,
        "longitude" => attrs.longitude
      }
    else
      {
        "address" => attrs.try(:address),
        "city" => attrs.try(:city),
        "state" => attrs.try(:state),
        "latitude" => attrs.try(:latitude),
        "longitude" => attrs.try(:longitude)
      }
    end
  end

  def build_query(attrs)
    parts = [
      attrs["address"].to_s.strip,
      attrs["city"].to_s.strip,
      attrs["state"].to_s.strip.presence || "Trinidad"
    ].reject(&:blank?).uniq
    query = parts.join(", ")
    return query if query.match?(/trinidad|tobago|barbados/i)

    "#{query}, Trinidad and Tobago"
  end

  def cached_resolve(query, region_hint)
    key = [
      "property_street_geocode/v1",
      Digest::SHA1.hexdigest([ query.to_s.downcase.strip, region_hint.to_s.downcase.strip ].join("|"))
    ]

    Rails.cache.fetch(key, expires_in: CACHE_TTL) do
      @google.resolve(query: query, region_hint: region_hint.presence || "Trinidad")
    end
  end

  def usable?(resolved)
    return false if resolved.nil?
    return false if resolved.latitude.blank? || resolved.longitude.blank?
    return false if resolved.confidence.to_i < MIN_CONFIDENCE

    types = []
    if resolved.raw.is_a?(Hash)
      types = Array(resolved.raw["types"]).map(&:to_s) + Array(resolved.raw["_types"]).map(&:to_s)
    end
    return false if types.include?("country")
    # City-only APPROXIMATE pins are no better than our centroids.
    return false if types.intersect?(%w[locality administrative_area_level_1 administrative_area_level_2 colloquial_area]) &&
                    resolved.location_type.to_s == "APPROXIMATE" &&
                    resolved.address.to_s.blank?

    true
  end
end
