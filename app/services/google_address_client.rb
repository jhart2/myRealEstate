require "net/http"
require "json"

# Resolves postal-style addresses via Google Geocoding (primary for TT/BB)
# and Address Validation where Google supports the region (e.g. US).
#
# Env: GOOGLE_MAPS_API_KEY (restricted to addressvalidation + geocoding-backend).
class GoogleAddressClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end

  GEOCODE_ENDPOINT = URI("https://maps.googleapis.com/maps/api/geocode/json").freeze
  VALIDATE_ENDPOINT = URI("https://addressvalidation.googleapis.com/v1:validateAddress").freeze

  # Address Validation region codes we will attempt. TT/BB are unsupported.
  VALIDATION_REGIONS = %w[US CA GB AU NZ].freeze

  Result = Struct.new(
    :formatted_address,
    :address,
    :city,
    :state,
    :zip,
    :latitude,
    :longitude,
    :place_id,
    :location_type,
    :confidence,
    :source,
    :raw,
    keyword_init: true
  )

  def self.resolve(**kwargs)
    new.resolve(**kwargs)
  end

  def initialize(api_key: ENV["GOOGLE_MAPS_API_KEY"])
    @api_key = api_key.to_s.strip.presence
  end

  def configured?
    @api_key.present?
  end

  # query: free-text address string
  # region_hint: "Trinidad" / "Barbados" / "US" / ISO region code
  def resolve(query:, region_hint: nil, components: nil)
    raise ConfigurationError, "GOOGLE_MAPS_API_KEY is not set" unless configured?

    region = normalize_region(region_hint)
    if VALIDATION_REGIONS.include?(region)
      validated = validate_address(query: query, region_code: region)
      return validated if validated&.confidence.to_i >= 70
    end

    geocode(query: query, region: region, components: components)
  end

  def geocode(query:, region: nil, components: nil)
    raise ConfigurationError, "GOOGLE_MAPS_API_KEY is not set" unless configured?

    cache_key = [
      "google_geocode/v1",
      Digest::SHA1.hexdigest(
        [ query.to_s.strip.downcase, region.to_s.downcase, components.to_s ].join("|")
      )
    ]

    Rails.cache.fetch(cache_key, expires_in: 30.days) do
      geocode_uncached(query: query, region: region, components: components)
    end
  end

  def geocode_uncached(query:, region: nil, components: nil)
    params = { address: query.to_s.strip, key: @api_key }
    params[:region] = region.downcase if region.present?
    params[:components] = components if components.present?

    uri = GEOCODE_ENDPOINT.dup
    uri.query = URI.encode_www_form(params)
    payload = get_json(uri)

    status = payload["status"].to_s
    unless status == "OK"
      return nil if %w[ZERO_RESULTS OVER_QUERY_LIMIT].include?(status)

      raise ApiError, "Geocoding #{status}: #{payload['error_message']}"
    end

    hit = payload.dig("results", 0)
    return nil unless hit

    normalize_geocode(hit)
  end

  def validate_address(query:, region_code:)
    raise ConfigurationError, "GOOGLE_MAPS_API_KEY is not set" unless configured?

    body = {
      address: {
        addressLines: [ query.to_s.strip ],
        regionCode: region_code.to_s.upcase
      }
    }
    uri = VALIDATE_ENDPOINT.dup
    uri.query = URI.encode_www_form(key: @api_key)
    payload = post_json(uri, body)

    if (err = payload["error"])
      message = err["message"].to_s
      return nil if message.match?(/Unsupported region/i)

      raise ApiError, "Address Validation: #{message}"
    end

    normalize_validation(payload["result"] || {})
  end

  private

  def normalize_region(hint)
    case hint.to_s.strip.downcase
    when "tt", "trinidad", "trinidad and tobago", "trinidad & tobago" then "TT"
    when "bb", "barbados" then "BB"
    when "us", "usa", "united states", "united states of america" then "US"
    when "ca", "canada" then "CA"
    when "gb", "uk", "united kingdom" then "GB"
    when "au", "australia" then "AU"
    when "nz", "new zealand" then "NZ"
    else
      hint.to_s.strip.upcase.presence
    end
  end

  def normalize_geocode(hit)
    components = index_components(hit["address_components"] || [])
    street = [
      components["street_number"]&.dig(:long),
      components["route"]&.dig(:long)
    ].compact.join(" ").presence

    # Plus Codes (e.g. JJM3+2XR) are not useful street lines for listings.
    street = nil if street.blank? || street.match?(/\A[A-Z0-9]{2,}\+[A-Z0-9]{2,}\z/i)

    city = components["neighborhood"]&.dig(:long) ||
           components["sublocality"]&.dig(:long) ||
           components["sublocality_level_1"]&.dig(:long) ||
           components["locality"]&.dig(:long) ||
           components["postal_town"]&.dig(:long) ||
           components["administrative_area_level_2"]&.dig(:long)

    country_short = components["country"]&.dig(:short).to_s.upcase
    admin = components["administrative_area_level_1"]&.dig(:long)
    state = island_state(country_short, admin) || admin

    loc = hit.dig("geometry", "location") || {}
    location_type = hit.dig("geometry", "location_type").to_s
    hit_types = Array(hit["types"]).map(&:to_s)
    confidence = geocode_confidence(location_type, street, hit_types)
    fallback_line = hit["formatted_address"].to_s.split(",").first.to_s.strip
    fallback_line = city if fallback_line.match?(/\A[A-Z0-9]{2,}\+[A-Z0-9]{2,}\z/i)

    Result.new(
      formatted_address: hit["formatted_address"],
      address: street.presence || fallback_line,
      city: city,
      state: state,
      zip: components["postal_code"]&.dig(:long),
      latitude: loc["lat"],
      longitude: loc["lng"],
      place_id: hit["place_id"],
      location_type: location_type,
      confidence: confidence,
      source: "geocoding",
      raw: hit.merge("_types" => hit_types)
    )
  end

  def normalize_validation(result)
    address = result["address"] || {}
    postal = address["postalAddress"] || {}
    geocode = result["geocode"] || {}
    loc = geocode["location"] || {}
    verdict = result["verdict"] || {}

    lines = Array(postal["addressLines"]).map { |l| l.to_s.strip }.reject(&:blank?)
    street = lines.first
    city = postal["locality"].presence || postal["sublocality"]
    country = postal["regionCode"].to_s.upcase
    state = country_to_state(country) || postal["administrativeArea"]
    confidence = validation_confidence(verdict)

    Result.new(
      formatted_address: address["formattedAddress"],
      address: street,
      city: city,
      state: state,
      zip: postal["postalCode"],
      latitude: loc["latitude"],
      longitude: loc["longitude"],
      place_id: geocode["placeId"],
      location_type: verdict["validationGranularity"].to_s,
      confidence: confidence,
      source: "address_validation",
      raw: result
    )
  end

  def country_to_state(code)
    island_state(code, nil)
  end

  # TT is one country; use admin area so Tobago listings stay Tobago.
  def island_state(country_code, admin)
    case country_code.to_s.upcase
    when "TT"
      admin.to_s.match?(/tobago/i) ? "Tobago" : "Trinidad"
    when "BB"
      "Barbados"
    end
  end

  def index_components(list)
    list.each_with_object({}) do |c, memo|
      types = Array(c["types"])
      types.each do |type|
        memo[type] ||= { long: c["long_name"], short: c["short_name"] }
      end
    end
  end

  def geocode_confidence(location_type, street, hit_types = [])
    base = case location_type
    when "ROOFTOP" then 95
    when "RANGE_INTERPOLATED" then 85
    when "GEOMETRIC_CENTER"
      hit_types.include?("route") || street.present? ? 75 : 65
    when "APPROXIMATE" then 45
    else 40
    end
    street.present? ? base : [ base - 20, 20 ].max
  end

  def validation_confidence(verdict)
    return 90 if verdict["addressComplete"] && verdict["possibleNextAction"].to_s == "ACCEPT"
    return 75 if verdict["addressComplete"]
    return 55 if verdict["hasInferredComponents"]
    35
  end

  def get_json(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 8
    http.read_timeout = 20

    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    response = http.request(request)
    parse_response!(response)
  end

  def post_json(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 8
    http.read_timeout = 20

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(body)
    response = http.request(request)
    parse_response!(response)
  end

  def parse_response!(response)
    parsed = JSON.parse(response.body)
    unless response.is_a?(Net::HTTPSuccess) || parsed["status"].present? || parsed["error"].present?
      raise ApiError, "Google HTTP #{response.code}: #{response.body.to_s.truncate(300)}"
    end
    parsed
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    raise ApiError, e.message
  end
end
