require "net/http"
require "json"

class PhotonGeocoder
  class Error < StandardError; end

  ENDPOINT = "https://photon.komoot.io/api/".freeze
  # Port of Spain — biases rankings toward Trinidad & Tobago.
  BIAS_LAT = 10.6549
  BIAS_LON = -61.5019
  # Rough TT bounding box (Trinidad + Tobago)
  TT_SOUTH = 10.0
  TT_NORTH = 11.45
  TT_WEST = -61.95
  TT_EAST = -60.4

  def self.search(query, limit: 8)
    new.search(query, limit: limit)
  end

  # Best single hit for map framing — Trinidad preferred.
  def self.resolve(query)
    new.resolve(query)
  end

  def resolve(query)
    hits = search(query, limit: 8)
    hits.find { |hit| within_tt?(hit[:lat], hit[:lng]) } || hits.first
  end

  def search(query, limit: 8)
    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(
      q: query,
      lat: BIAS_LAT,
      lon: BIAS_LON,
      limit: limit * 2,
      lang: "en"
    )

    response = fetch(uri)
    features = response.fetch("features", [])

    ranked = features.map { |feature| normalize(feature) }.compact
    prefer_tt = ranked.select { |r| r[:in_tt] } + ranked.reject { |r| r[:in_tt] }
    # Prefer real places over rivers/peaks when ranks are otherwise similar
    prefer_tt = prefer_tt.sort_by { |r| place_rank(r[:type]) }
    prefer_tt.first(limit).map { |r| r.except(:in_tt).merge(lat: r[:lat], lng: r[:lng]) }
  end

  private

  def place_rank(type)
    case type.to_s
    when "city", "town", "village", "district", "locality", "county", "state" then 0
    when "street", "house" then 1
    else 2
    end
  end

  def fetch(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 4
    http.read_timeout = 6

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "EstateRealty/1.0 (location autocomplete; +https://mybunchofkeys.com)"
    request["Accept"] = "application/json"

    response = http.request(request)
    raise Error, "Photon HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    raise Error, e.message
  end

  def normalize(feature)
    geometry = feature["geometry"] || {}
    coords = geometry["coordinates"]
    return nil unless coords.is_a?(Array) && coords.size >= 2

    lng, lat = coords[0].to_f, coords[1].to_f
    props = feature["properties"] || {}

    name = props["name"].presence
    return nil if name.blank?

    parts = [
      name,
      props["city"],
      props["county"],
      props["state"],
      props["country"]
    ].compact.map(&:strip).uniq

    label = parts.join(", ")
    countrycode = props["countrycode"].to_s.downcase
    in_tt = countrycode == "tt" || within_tt?(lat, lng)
    bounds = bounds_for(props, lat, lng)

    {
      id: feature["properties"]&.dig("osm_id") || label,
      name: name,
      label: label,
      type: props["type"].presence || props["osm_value"].presence || "place",
      lat: lat,
      lng: lng,
      north: bounds[:north],
      south: bounds[:south],
      east: bounds[:east],
      west: bounds[:west],
      in_tt: in_tt
    }
  end

  # Photon extent is [minLon, maxLat, maxLon, minLat] → west, north, east, south.
  def bounds_for(props, lat, lng)
    extent = props["extent"]
    if extent.is_a?(Array) && extent.size >= 4
      west, north, east, south = extent.map(&:to_f)
      # Normalize in case a provider swaps corners
      south, north = [ south, north ].minmax
      west, east = [ west, east ].minmax
      pad_lat = [ (north - south) * 0.08, 0.004 ].max
      pad_lng = [ (east - west) * 0.08, 0.004 ].max
      return {
        north: (north + pad_lat).round(6),
        south: (south - pad_lat).round(6),
        east: (east + pad_lng).round(6),
        west: (west - pad_lng).round(6)
      }
    end

    pad = case props["type"].to_s
    when "city", "county", "state" then 0.028
    when "district", "locality", "town", "village" then 0.014
    else 0.01
    end

    {
      north: (lat + pad).round(6),
      south: (lat - pad).round(6),
      east: (lng + pad).round(6),
      west: (lng - pad).round(6)
    }
  end

  def within_tt?(lat, lng)
    lat.between?(TT_SOUTH, TT_NORTH) && lng.between?(TT_WEST, TT_EAST)
  end
end
