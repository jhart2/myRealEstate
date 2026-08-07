class PropertiesController < ApplicationController
  allow_unauthenticated_access only: %i[index show]

  def index
    @properties = Property.search(search_params).includes(:agent, image_attachment: :blob)
    @intent = params[:intent].presence || "all"
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
    @sort = params[:sort].presence || "featured"
    @sqft_min = params[:sqft_min].presence
    @sqft_max = params[:sqft_max].presence
    @acres_min = params[:acres_min].presence
    @days_max = params[:days_max].presence
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
    @price_histogram = Property.price_histogram(search_params)
    @hide_footer = true
  end

  def show
    @property = Property.active.includes(:agent, :favorites).find_by!(slug: params[:id])
    @inquiry = Inquiry.new(property: @property, name: current_user&.name, email: current_user&.email_address)
    @related = Property.active.where(property_type: @property.property_type).where.not(id: @property.id).limit(3)
    @property.record_view!(session)

    if turbo_frame_request? && turbo_frame_request_id == "property_lightbox"
      render partial: "properties/lightbox_frame", layout: false
      return
    end
  end

  private

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
    when "Under $500K" then [0, 500_000]
    when "$500K – $1M" then [500_000, 1_000_000]
    when "$1M – $3M" then [1_000_000, 3_000_000]
    when "$3M – $7M" then [3_000_000, 7_000_000]
    when "$7M+" then [7_000_000, nil]
    when "Under $3K / mo" then [0, 600_000]
    when "$3K – $6K / mo" then [600_000, 1_200_000]
    when "$6K+ / mo" then [1_200_000, nil]
    end
  end
end
