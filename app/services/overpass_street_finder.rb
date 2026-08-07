# frozen_string_literal: true

require "net/http"
require "json"
require "cgi"

# Find highway/street center points inside a community bbox via the public
# Overpass API (OpenStreetMap). Used when Photon/Nominatim miss TT streets.
#
#   OverpassStreetFinder.find(name: "Daniel Drive", city: "Champs Fleurs")
class OverpassStreetFinder
  class Error < StandardError; end

  ENDPOINT = URI("https://overpass-api.de/api/interpreter").freeze
  FALLBACK_ENDPOINT = URI("https://overpass.kumi.systems/api/interpreter").freeze
  USER_AGENT = "TTRealty/1.0 (street-in-bbox reconcile; local; +https://estate.realty)".freeze
  MIN_INTERVAL = 1.2
  # ~4.5km pad around a city centroid when archived boundary is tiny/missing.
  DEFAULT_PAD = 0.04
  MIN_BBOX_SPAN = 0.015

  Result = Struct.new(:latitude, :longitude, :name, :osm_id, :highway, :source, :bbox, keyword_init: true)

  @last_request_at = nil
  @mutex = Mutex.new

  class << self
    def find(name:, city: nil, state: nil)
      new.find(name: name, city: city, state: state)
    end

    def throttle!
      @mutex.synchronize do
        if @last_request_at
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_at
          sleep(MIN_INTERVAL - elapsed) if elapsed < MIN_INTERVAL
        end
        @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  def find(name:, city: nil, state: nil)
    street = normalize_name(name)
    return nil if street.blank?

    bbox = bbox_for(city: city, state: state)
    return nil unless bbox

    hits = query_overpass(street, bbox)
    pick = pick_best(hits, street)
    return nil unless pick

    Result.new(
      latitude: pick[:lat],
      longitude: pick[:lng],
      name: pick[:name],
      osm_id: pick[:osm_id],
      highway: pick[:highway],
      source: "overpass",
      bbox: bbox
    )
  end

  private

  def normalize_name(value)
    value.to_s
      .sub(/\A#?\d+[a-z]?\s+/i, "")
      .gsub(/\s+/, " ")
      .strip
      .presence
  end

  def bbox_for(city:, state:)
    feature = GeoBoundaryLookup.find(city.to_s) if city.present?
    if feature
      bbox = feature["bbox"] || bounds_from_geometry(feature["geometry"])
      if usable_bbox?(bbox)
        return expand_bbox(bbox, pad: 0.01)
      end
    end

    key = city.to_s.downcase.strip
    coords = BokListingsImporter::CITY_COORDS[key]
    coords ||= BokListingsImporter::CITY_COORDS.find { |n, _| key.include?(n) || n.include?(key) }&.last
    return nil unless coords

    pad = DEFAULT_PAD
    # Tobago communities: slightly wider pad
    pad = 0.06 if state.to_s.match?(/tobago/i) || key.include?("tobago")
    lat, lng = coords
    [ lng - pad, lat - pad, lng + pad, lat + pad ]
  end

  def usable_bbox?(bbox)
    return false unless bbox.is_a?(Array) && bbox.size >= 4

    west, south, east, north = bbox.map(&:to_f)
    (east - west) >= MIN_BBOX_SPAN || (north - south) >= MIN_BBOX_SPAN
  end

  def expand_bbox(bbox, pad:)
    west, south, east, north = bbox.map(&:to_f)
    [ west - pad, south - pad, east + pad, north + pad ]
  end

  def bounds_from_geometry(geometry)
    return nil unless geometry.is_a?(Hash)

    coords = flatten_coords(geometry["coordinates"])
    return nil if coords.empty?

    lngs = coords.map(&:first)
    lats = coords.map(&:last)
    [ lngs.min, lats.min, lngs.max, lats.max ]
  end

  def flatten_coords(node, out = [])
    case node
    when Array
      if node.size >= 2 && node[0].is_a?(Numeric)
        out << [ node[0].to_f, node[1].to_f ]
      else
        node.each { |child| flatten_coords(child, out) }
      end
    end
    out
  end

  def query_overpass(street, bbox)
    self.class.throttle!
    west, south, east, north = bbox
    # Prefer exact-ish name, then contains name without suffix noise.
    core = street.gsub(/[^\w\s'-]/, " ").squeeze(" ").strip
    escaped = Regexp.escape(core).gsub('\\ ', "[ -]*")

    query = <<~QL
      [out:json][timeout:25];
      (
        way["highway"]["name"~"^#{escaped}$",i](#{south},#{west},#{north},#{east});
        way["highway"]["name"~"#{escaped}",i](#{south},#{west},#{north},#{east});
      );
      out center tags 12;
    QL

    payload = post(query)
    Array(payload["elements"]).filter_map { |el| normalize_element(el) }
  end

  def post(query)
    last_error = nil
    [ ENDPOINT, FALLBACK_ENDPOINT ].each do |endpoint|
      begin
        return post_to(endpoint, query)
      rescue Error => e
        last_error = e
        sleep 0.8
      end
    end
    raise last_error
  end

  def post_to(endpoint, query)
    http = Net::HTTP.new(endpoint.host, endpoint.port)
    http.use_ssl = true
    http.open_timeout = 8
    http.read_timeout = 35

    request = Net::HTTP::Post.new(endpoint)
    request["User-Agent"] = USER_AGENT
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request.body = "data=#{CGI.escape(query)}"

    response = http.request(request)
    raise Error, "Overpass HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    raise Error, e.message
  end

  def normalize_element(el)
    tags = el["tags"] || {}
    name = tags["name"].to_s.presence
    return nil if name.blank?

    lat = el.dig("center", "lat") || el["lat"]
    lng = el.dig("center", "lon") || el["lon"]
    return nil if lat.blank? || lng.blank?

    {
      name: name,
      lat: lat.to_f,
      lng: lng.to_f,
      osm_id: el["id"],
      highway: tags["highway"].to_s
    }
  end

  def pick_best(hits, street)
    return nil if hits.blank?

    needle = street.downcase
    scored = hits.map do |h|
      hay = h[:name].to_s.downcase
      score =
        if hay == needle then 100
        elsif hay.start_with?(needle) || needle.start_with?(hay) then 80
        elsif hay.include?(needle) || needle.include?(hay) then 60
        else 20
        end
      [ score, h ]
    end
    scored.max_by(&:first)&.last
  end
end
