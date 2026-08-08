class PropertiesController < ApplicationController
  allow_unauthenticated_access only: %i[index show photo_download results map_markers price_histogram]

  PER_PAGE = 48
  MAP_MARKERS_CAP = 3_000

  def index
    prepare_search_scope!
    paginate_search!
    assign_map_frame!
    @hide_footer = true
  end

  # HTML fragment / JSON used by continuous scroll + viewport list refresh.
  def results
    prepare_search_scope!
    paginate_search!

    html = render_to_string(
      partial: "properties/search_card",
      collection: @properties,
      as: :property,
      formats: [ :html ]
    )

    render json: {
      totalCount: @total_count,
      page: @page,
      totalPages: @total_pages,
      hasMore: @page < @total_pages,
      html: html
    }
  end

  # Lightweight pin payload for the current filter (+ viewport bounds when present).
  def map_markers
    prepare_search_scope!

    listings =
      @search_scope
        .where.not(latitude: nil)
        .where.not(longitude: nil)
        .limit(MAP_MARKERS_CAP)
        .map(&:as_map_json)

    render json: listings
  end

  # Listing-density bars for the price filter (ignores current price/budget range).
  def price_histogram
    prepare_search_scope!

    render json: {
      buckets: Property.price_histogram(index_search_params),
      bucketCount: Property::PRICE_HISTOGRAM_BUCKETS,
      maxDollars: Property::PRICE_HISTOGRAM_MAX_DOLLARS
    }
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
  # Watermark stamping is temporarily disabled.
  def photo_download
    property = Property.active.with_attached_gallery_images.find_by!(slug: params[:id])
    index = Integer(params[:index])
    raise ActiveRecord::RecordNotFound if index.negative?

    filename = property.gallery_download_filename(index)

    if (image = property.hosted_gallery_images[index])
      blob = image.blob
      send_photo_bytes!(
        blob.download,
        filename: filename,
        content_type: blob.content_type.presence || "image/jpeg"
      )
      return
    end

    url = property.gallery_image_urls[index].to_s
    raise ActiveRecord::RecordNotFound if url.blank?

    if url.start_with?("/")
      absolute = "#{request.base_url}#{url}"
      payload = PropertyGalleryIngestor.download(absolute)
      send_photo_bytes!(
        payload[:io].read,
        filename: filename,
        content_type: payload[:content_type].presence || "image/jpeg"
      )
      return
    end

    payload = PropertyGalleryIngestor.download(url)
    send_photo_bytes!(
      payload[:io].read,
      filename: filename,
      content_type: payload[:content_type].presence || "image/jpeg"
    )
  rescue ArgumentError, PropertyGalleryIngestor::DownloadError
    raise ActiveRecord::RecordNotFound
  end

  private

  def send_photo_bytes!(binary, filename:, content_type:)
    send_data binary,
              filename: filename,
              type: content_type,
              disposition: "attachment"
  end

  # Kept for an easy re-enable later (overlay is also hidden in CSS for now).
  def send_watermarked_photo!(binary, filename:, content_type:)
    stamped =
      begin
        GalleryPhotoWatermarker.call(binary, content_type: content_type)
      rescue GalleryPhotoWatermarker::Error => e
        Rails.logger.warn("[photo_download] watermark failed: #{e.message}")
        binary
      end

    send_data stamped,
              filename: filename,
              type: "image/jpeg",
              disposition: "attachment"
  end

  # Shared filter context + ActiveRecord scope. Does not paginate, load markers, or histogram.
  def prepare_search_scope!
    @intent = normalize_intent(params[:intent])
    @sort = params[:sort].presence || (@intent == "new" ? "newest" : "featured")
    @days_max = params[:days_max].presence
    @days_max ||= Property.new_listing_days.to_s if @intent == "new"

    # CDN cover URLs only on search cards/map — do not preload gallery blobs.
    @search_scope = Property.search(index_search_params)

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
  end

  def paginate_search!
    @total_count = @search_scope.except(:order).count
    @per_page = PER_PAGE
    @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
    @page = [ [ params[:page].to_i, 1 ].max, @total_pages ].min
    @properties = @search_scope.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def assign_map_frame!
    @map_boundary = GeoBoundaryLookup.find(@location)
    @map_viewport = MapViewport.for(
      location: @location,
      north: params[:north],
      south: params[:south],
      east: params[:east],
      west: params[:west]
    ) unless @map_boundary
  end

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
      :north, :south, :east, :west, :page,
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
