class PropertiesController < ApplicationController
  allow_unauthenticated_access only: %i[index show photo_download]

  def index
    @intent = normalize_intent(params[:intent])
    @sort = params[:sort].presence || (@intent == "new" ? "newest" : "featured")
    @days_max = params[:days_max].presence
    @days_max ||= Property.new_listing_days.to_s if @intent == "new"

    query = index_search_params
    # Index cards/map use listing_cover_url (CDN columns) — do not preload every
    # gallery blob (that plus per-listing .includes(:blob) caused ~12k SQL queries).
    @properties = Property.search(query).includes(:agent)
    @location = params[:location]
    @property_types = Array(params[:property_types]).map(&:presence).compact
    if @property_types.empty? && params[:property_type].present? && params[:property_type] != "Any Type"
      @property_types = [ params[:property_type] ]
    end
    @property_types &= Property::PROPERTY_TYPES
    @property_type = @property_types.first
    @budget = params[:budget]
    @price_min = params[:price_min].presence
    @price_max = params[:price_max].presence
    if @price_min.blank? && @price_max.blank? && (bounds = budget_to_price_bounds(@budget))
      @price_min, @price_max = bounds.map { |v| v&.to_s }
    end
    @beds = params[:beds]
    @baths = params[:baths]
    @sqft_min = params[:sqft_min].presence
    @sqft_max = params[:sqft_max].presence
    @acres_min = params[:acres_min].presence
    @featured_only = params[:featured].to_s.in?(%w[1 true])
    @map_listings = @properties.select(&:mappable?).map(&:as_map_json)
    @map_boundary = GeoBoundaryLookup.find(@location)
    @map_viewport = MapViewport.for(
      location: @location,
      north: params[:north],
      south: params[:south],
      east: params[:east],
      west: params[:west]
    ) unless @map_boundary
    @price_histogram = Property.price_histogram(query)
    @hide_footer = true
  end

  def show
    @property = Property.active.includes(:agent, :favorites).with_attached_gallery_images.find_by!(slug: params[:id])
    @inquiry = Inquiry.new(property: @property, name: current_user&.name, email: current_user&.email_address)
    @related = Property.active.where(property_type: @property.property_type).where.not(id: @property.id).with_attached_gallery_images.limit(3)
    @property.record_view!(session)

    if turbo_frame_request? && turbo_frame_request_id == "property_lightbox"
      render partial: "properties/lightbox_frame", layout: false
      nil
    end
  end

  # Same-origin download so gallery "Download" keeps the user gesture (mobile-safe)
  # and forces Content-Disposition: attachment with a clean slug-index filename.
  def photo_download
    property = Property.active.with_attached_gallery_images.find_by!(slug: params[:id])
    index = Integer(params[:index])
    raise ActiveRecord::RecordNotFound if index.negative?

    filename = property.gallery_download_filename(index)

    if (image = property.hosted_gallery_images[index])
      blob = image.blob
      send_data blob.download,
                filename: filename,
                type: blob.content_type.presence || "image/jpeg",
                disposition: "attachment"
      return
    end

    url = property.gallery_image_urls[index].to_s
    raise ActiveRecord::RecordNotFound if url.blank?

    if url.start_with?("/")
      # Relative Active Storage URL without a hosted attachment mapping — follow and re-send.
      absolute = "#{request.base_url}#{url}"
      payload = PropertyGalleryIngestor.download(absolute)
      send_data payload[:io].read,
                filename: filename,
                type: payload[:content_type].presence || "image/jpeg",
                disposition: "attachment"
      return
    end

    payload = PropertyGalleryIngestor.download(url)
    send_data payload[:io].read,
              filename: filename,
              type: payload[:content_type].presence || "application/octet-stream",
              disposition: "attachment"
  rescue ArgumentError, PropertyGalleryIngestor::DownloadError
    raise ActiveRecord::RecordNotFound
  end

  private

  def normalize_intent(raw)
    intent = raw.to_s
    return intent if %w[sale rent new all].include?(intent)

    "all"
  end

  def index_search_params
    search_params.to_h.merge(
      "intent" => @intent == "all" ? nil : @intent,
      "sort" => @sort,
      "days_max" => @days_max
    ).compact
  end

  def search_params
    params.permit(
      :intent, :location, :region, :property_type, :budget, :price_min, :price_max,
      :beds, :baths, :sort, :sqft_min, :sqft_max, :acres_min, :days_max, :featured,
      :north, :south, :east, :west,
      property_types: []
    )
  end

  def budget_to_price_bounds(budget)
    case budget.to_s
    when "Under $500K" then [ 0, 500_000 ]
    when "$500K – $1M" then [ 500_000, 1_000_000 ]
    when "$1M – $3M" then [ 1_000_000, 3_000_000 ]
    when "$3M – $7M" then [ 3_000_000, 7_000_000 ]
    when "$7M+" then [ 7_000_000, nil ]
    when "Under $3K / mo" then [ 0, 600_000 ]
    when "$3K – $6K / mo" then [ 600_000, 1_200_000 ]
    when "$6K+ / mo" then [ 1_200_000, nil ]
    end
  end
end
