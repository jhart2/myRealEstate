require "net/http"
require "json"

# Drive-time estimates via the public OSRM demo router (TT-biased listings).
class TravelController < ApplicationController
  allow_unauthenticated_access only: :estimate

  OSRM = "https://router.project-osrm.org/route/v1/driving".freeze

  def estimate
    from_lat = params[:from_lat].to_f
    from_lng = params[:from_lng].to_f
    to_lat = params[:to_lat].to_f
    to_lng = params[:to_lng].to_f

    unless valid_coord?(from_lat, from_lng) && valid_coord?(to_lat, to_lng)
      return render json: { error: "invalid_coordinates" }, status: :unprocessable_entity
    end

    uri = URI("#{OSRM}/#{from_lng},#{from_lat};#{to_lng},#{to_lat}")
    uri.query = URI.encode_www_form(overview: "false", alternatives: "false", steps: "false")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 4
    http.read_timeout = 6

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "EstateRealty/1.0 (travel estimate)"
    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      return render json: { error: "routing_unavailable" }, status: :bad_gateway
    end

    payload = JSON.parse(response.body)
    route = payload.dig("routes", 0)
    if route.blank?
      return render json: { error: "no_route" }, status: :not_found
    end

    seconds = route["duration"].to_f
    meters = route["distance"].to_f

    render json: {
      duration_minutes: (seconds / 60.0).round,
      distance_km: (meters / 1000.0).round(1),
      mode: "driving"
    }
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    Rails.logger.warn("[travel] #{e.message}")
    render json: { error: "routing_unavailable" }, status: :bad_gateway
  end

  private

  def valid_coord?(lat, lng)
    lat.between?(-90, 90) && lng.between?(-180, 180) && !(lat == 0.0 && lng == 0.0)
  end
end
