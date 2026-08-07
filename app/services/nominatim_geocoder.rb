# frozen_string_literal: true

require "net/http"
require "json"

# Public OpenStreetMap Nominatim geocoder (no API key).
# Usage policy: identify app via User-Agent, ≤1 request/second.
#
#   NominatimGeocoder.search("Daniel Drive, Champs Fleurs")
#   NominatimGeocoder.resolve("156 Anne Avenue, Palmiste, Trinidad")
class NominatimGeocoder
  class Error < StandardError; end

  ENDPOINT = "https://nominatim.openstreetmap.org/search".freeze
  USER_AGENT = "TTRealty/1.0 (listing coord reconcile; local support; +https://estate.realty)".freeze
  MIN_INTERVAL = 1.1

  # Trinidad + Tobago rough bbox
  TT_SOUTH = 10.0
  TT_NORTH = 11.45
  TT_WEST = -61.95
  TT_EAST = -60.4

  # Barbados rough bbox
  BB_SOUTH = 12.98
  BB_NORTH = 13.35
  BB_WEST = -59.66
  BB_EAST = -59.40

  Result = Struct.new(
    :latitude,
    :longitude,
    :display_name,
    :osm_type,
    :osm_class,
    :osm_value,
    :place_rank,
    :importance,
    :address,
    :city,
    :state,
    :country_code,
    :source,
    :raw,
    keyword_init: true
  )

  @last_request_at = nil
  @mutex = Mutex.new

  class << self
    def search(query, limit: 5, countrycodes: "tt,bb")
      new.search(query, limit: limit, countrycodes: countrycodes)
    end

    def resolve(query, limit: 5, countrycodes: "tt,bb")
      new.resolve(query, limit: limit, countrycodes: countrycodes)
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

  def search(query, limit: 5, countrycodes: "tt,bb")
    q = query.to_s.strip
    return [] if q.blank?

    self.class.throttle!

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(
      q: q,
      format: "jsonv2",
      addressdetails: 1,
      limit: limit,
      countrycodes: countrycodes,
      # Bias toward TT; still allow BB hits via countrycodes.
      viewbox: "#{TT_WEST},#{TT_NORTH},#{TT_EAST},#{TT_SOUTH}",
      bounded: 0
    )

    payload = fetch(uri)
    Array(payload).filter_map { |hit| normalize(hit) }
  end

  def resolve(query, limit: 5, countrycodes: "tt,bb")
    hits = search(query, limit: limit, countrycodes: countrycodes)
    pick_best(hits)
  end

  def pick_best(hits)
    return nil if hits.blank?

    hits.max_by { |h| score(h) }
  end

  def score(hit)
    value = hit.osm_value.to_s
    klass = hit.osm_class.to_s
    base =
      case
      when value == "house" || klass == "building" then 100
      when value == "yes" && klass == "place" then 40
      when %w[residential living_street tertiary secondary primary unclassified service].include?(value) then 85
      when value == "road" || klass == "highway" then 80
      when %w[suburb neighbourhood quarter].include?(value) then 45
      when %w[city town village hamlet locality].include?(value) then 25
      else 35
      end

    base += 10 if hit.address.present?
    base += (hit.importance.to_f * 10)
    base
  end

  private

  def fetch(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 6
    http.read_timeout = 12

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = USER_AGENT
    request["Accept"] = "application/json"
    request["Accept-Language"] = "en"

    response = http.request(request)
    raise Error, "Nominatim HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    raise Error, e.message
  end

  def normalize(hit)
    lat = hit["lat"]&.to_f
    lng = hit["lon"]&.to_f
    return nil if lat.blank? || lng.blank?
    return nil unless in_region?(lat, lng)

    addr = hit["address"] || {}
    Result.new(
      latitude: lat,
      longitude: lng,
      display_name: hit["display_name"].to_s,
      osm_type: hit["osm_type"].to_s,
      osm_class: hit["category"].presence || hit["class"].to_s,
      osm_value: hit["type"].presence || hit["addresstype"].to_s,
      place_rank: hit["place_rank"]&.to_i,
      importance: hit["importance"]&.to_f,
      address: [
        addr["house_number"],
        addr["road"] || addr["pedestrian"] || addr["path"]
      ].compact.join(" ").presence,
      city: addr["city"] || addr["town"] || addr["village"] || addr["suburb"] || addr["hamlet"],
      state: addr["state"] || addr["county"],
      country_code: (addr["country_code"] || hit["country_code"]).to_s.downcase,
      source: "nominatim",
      raw: hit
    )
  end

  def in_region?(lat, lng)
    in_tt?(lat, lng) || in_bb?(lat, lng)
  end

  def in_tt?(lat, lng)
    lat.between?(TT_SOUTH, TT_NORTH) && lng.between?(TT_WEST, TT_EAST)
  end

  def in_bb?(lat, lng)
    lat.between?(BB_SOUTH, BB_NORTH) && lng.between?(BB_WEST, BB_EAST)
  end
end
