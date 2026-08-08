# Camera frame for a search when no archived OSM polygon is available.
# Prefer explicit N/S/E/W (autocomplete / "Search this area"), else geocode the location text.
class MapViewport
  TT_SOUTH = PhotonGeocoder::TT_SOUTH
  TT_NORTH = PhotonGeocoder::TT_NORTH
  TT_WEST = PhotonGeocoder::TT_WEST
  TT_EAST = PhotonGeocoder::TT_EAST

  def self.for(location:, north: nil, south: nil, east: nil, west: nil)
    from_params(location:, north:, south:, east:, west:) || from_geocode(location)
  end

  def self.from_params(location:, north:, south:, east:, west:)
    values = [ north, south, east, west ].map { |v| v.presence }
    return nil unless values.all?

    south_f, west_f, north_f, east_f = [
      south.to_f, west.to_f, north.to_f, east.to_f
    ]
    return nil if south_f >= north_f || west_f >= east_f
    return nil unless overlaps_tt?(south_f, west_f, north_f, east_f)

    south_f = [ south_f, TT_SOUTH ].max
    north_f = [ north_f, TT_NORTH ].min
    west_f = [ west_f, TT_WEST ].max
    east_f = [ east_f, TT_EAST ].min
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
    return nil unless within_tt?(hit[:lat], hit[:lng])

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

  def self.overlaps_tt?(south, west, north, east)
    south < TT_NORTH && north > TT_SOUTH && west < TT_EAST && east > TT_WEST
  end

  def self.within_tt?(lat, lng)
    return false if lat.nil? || lng.nil?

    lat.to_f.between?(TT_SOUTH, TT_NORTH) && lng.to_f.between?(TT_WEST, TT_EAST)
  end
  private_class_method :overlaps_tt?, :within_tt?
end
