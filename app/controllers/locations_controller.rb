class LocationsController < ApplicationController
  allow_unauthenticated_access only: :autocomplete

  # Proxies Photon (OSM) geocoding so the browser doesn't hit CORS / rate-limit issues.
  # Biased toward Trinidad & Tobago.
  def autocomplete
    query = params[:q].to_s.strip
    if query.length < 2
      return render json: { results: [] }
    end

    results = PhotonGeocoder.search(query)
    render json: { results: results }
  rescue PhotonGeocoder::Error => e
    Rails.logger.warn("[locations] #{e.message}")
    render json: { results: [], error: "lookup_failed" }, status: :ok
  end
end
