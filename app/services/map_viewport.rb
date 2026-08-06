# Camera frame for a search when no archived OSM polygon is available.
# Prefer explicit N/S/E/W (autocomplete / "Search this area"), else geocode the location text.
class MapViewport
  def self.for(location:, north: nil, south: nil, east: nil, west: nil)
    from_params(location:, north:, south:, east:, west:) || from_geocode(location)
  end

  def self.from_params(location:, north:, south:, east:, west:)
    values = [north, south, east, west].map { |v| v.presence }
    return nil unless values.all?

    south_f, west_f, north_f, east_f = [
      south.to_f, west.to_f, north.to_f, east.to_f
    ]
    return nil if south_f >= north_f || west_f >= east_f

    {
      north: north_f.round(6),
      south: south_f.round(6),
      east: east_f.round(6),
      west: west_f.round(6),
      lat: ((north_f + south_f) / 2.0).round(6),
      lng: ((east_f + west_f) / 2.0).round(6)
    }
  end

  def self.from_geocode(location)
    return nil if location.blank?

    hit = PhotonGeocoder.resolve(location)
    return nil unless hit

    {
      north: hit[:north],
      south: hit[:south],
      east: hit[:east],
      west: hit[:west],
      lat: hit[:lat],
      lng: hit[:lng]
    }.compact.presence
  rescue PhotonGeocoder::Error => e
    Rails.logger.warn("[map_viewport] #{e.message}")
    nil
  end
end
