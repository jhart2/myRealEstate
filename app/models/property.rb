class Property < ApplicationRecord
  include ImageAttachable

  belongs_to :agent, optional: true, counter_cache: :listings_count
  has_many :favorites, dependent: :destroy
  has_many :favorited_by_users, through: :favorites, source: :user
  has_many :inquiries, dependent: :destroy

  TAGS = %w[sale rent new].freeze
  PROPERTY_TYPES = %w[House Apartment Townhouse Villa Penthouse Commercial Land Modern\ Home].freeze
  STATUSES = %w[active pending sold rented].freeze

  scope :active, -> { where(status: "active") }
  scope :featured, -> { active.where(featured: true) }
  scope :for_sale, -> { active.where(tag: "sale") }
  scope :for_rent, -> { active.where(tag: "rent") }
  scope :new_homes, -> { active.where(tag: "new") }
  scope :by_type, ->(type) { where(property_type: type) if type.present? }

  validates :title, :address, :city, :state, :price_cents, :tag, :property_type, presence: true
  validates :tag, inclusion: { in: TAGS }
  validates :property_type, inclusion: { in: PROPERTY_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :slug, presence: true, uniqueness: true
  validates :bok_id, uniqueness: true, allow_nil: true
  validates :source_url, uniqueness: true, allow_nil: true

  before_validation :generate_slug, on: :create
  before_validation :set_price_label
  before_validation :sync_lot_size_fields

  def price_dollars
    return if price_cents.blank?

    (BigDecimal(price_cents.to_s) / 100).to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, '\1')
  end

  def price_dollars=(value)
    raw = value.to_s.gsub(/[,\s]/, "")
    if raw.blank?
      self.price_cents = nil
    else
      self.price_cents = (BigDecimal(raw) * 100).round
    end
  rescue ArgumentError
    self.price_cents = nil
  end


  def self.search(params = {})
    scope = active
    scope = scope.where(tag: params[:intent]) if params[:intent].present? && TAGS.include?(params[:intent])

    types = Array(params[:property_types]).map(&:presence).compact
    if types.empty? && params[:property_type].present? && params[:property_type] != "Any Type"
      types = [ params[:property_type] ]
    end
    types &= PROPERTY_TYPES
    scope = scope.where(property_type: types) if types.any?

    # Map viewport bounds win over text location (Zillow-style area search).
    if params.values_at(:north, :south, :east, :west).all?(&:present?)
      scope = scope.in_bounds(
        north: params[:north].to_f,
        south: params[:south].to_f,
        east: params[:east].to_f,
        west: params[:west].to_f
      )
    elsif params[:region].present? && TrinidadRegion.find(params[:region])
      scope = scope.in_region(params[:region])
    elsif params[:location].present?
      term = "%#{params[:location].strip}%"
      scope = scope.where("city LIKE ? OR state LIKE ? OR zip LIKE ? OR address LIKE ? OR title LIKE ?", term, term, term, term, term)
    end

    if params[:price_min].present? || params[:price_max].present?
      min_cents = params[:price_min].to_i * 100
      max_raw = params[:price_max].to_s.strip
      if max_raw.blank? || max_raw == "0"
        scope = scope.where("price_cents >= ?", min_cents)
      else
        scope = scope.where(price_cents: min_cents..(max_raw.to_i * 100))
      end
    elsif params[:budget].present? && params[:budget] != "Any Price"
      range = budget_range(params[:budget])
      scope = scope.where(price_cents: range) if range
    end

    if params[:beds].present?
      scope = scope.where("beds >= ?", params[:beds].to_i)
    end

    if params[:baths].present?
      scope = scope.where("baths >= ?", params[:baths].to_i)
    end

    if params[:sqft_min].present?
      scope = scope.where("sqft >= ?", params[:sqft_min].to_i)
    end

    if params[:sqft_max].present?
      scope = scope.where("sqft <= ?", params[:sqft_max].to_i)
    end

    if params[:acres_min].present?
      scope = scope.where("acres >= ?", params[:acres_min].to_f)
    end

    if params[:days_max].present?
      scope = scope.where("created_at >= ?", params[:days_max].to_i.days.ago.beginning_of_day)
    end

    if params[:featured].to_s.in?(%w[1 true])
      scope = scope.where(featured: true)
    end

    scope = case params[:sort]
    when "price_asc" then scope.order(price_cents: :asc)
    when "price_desc" then scope.order(price_cents: :desc)
    when "newest" then scope.order(created_at: :desc)
    else scope.order(featured: :desc, created_at: :desc)
    end

    scope
  end

  def self.in_bounds(north:, south:, east:, west:)
    where(latitude: south..north, longitude: west..east)
  end

  def self.in_region(key_or_slug)
    region = TrinidadRegion.find(key_or_slug)
    return none unless region

    words = TrinidadRegion::KEYWORDS.fetch(region.key)
    clauses = words.map { "LOWER(city) LIKE ?" }
    where(clauses.join(" OR "), *words.map { |w| "%#{w}%" })
  end

  def self.homepage_region_rows(per_region: 12)
    by_region = active
      .includes(:agent, image_attachment: :blob)
      .order(featured: :desc, views_count: :desc, created_at: :desc)
      .group_by { |property| property.region.key }

    TrinidadRegion::ALL.filter_map do |region|
      listings = Array(by_region[region.key]).first(per_region)
      next if listings.empty?

      { region: region, properties: listings }
    end
  end

  def region
    @region ||= TrinidadRegion.classify(city: city, latitude: latitude, longitude: longitude)
  end

  def region_headline
    type = property_type.presence || "Home"
    "#{type} in #{short_place_name}"
  end

  def short_place_name
    TrinidadRegion.place_label(city).presence || state.presence || "Trinidad"
  end
  def mappable?
    latitude.present? && longitude.present?
  end

  def map_price_label(currency: Current.currency)
    MoneyDisplay.compact(price_cents, currency: currency, rent: tag == "rent")
  end

  def as_map_json
    {
      id: id,
      slug: slug,
      title: title,
      price: display_price,
      priceLabel: map_price_label,
      beds: beds.to_i,
      baths: baths.to_i,
      sqft: sqft,
      sqftLabel: sqft.present? ? ActiveSupport::NumberHelper.number_to_delimited(sqft) : nil,
      address: full_address,
      tag: tag_label,
      statusLabel: listing_status_label,
      propertyType: property_type,
      lat: latitude&.to_f,
      lng: longitude&.to_f,
      image: display_image_url,
      url: Rails.application.routes.url_helpers.property_path(self)
    }
  end

  def listing_status_label
    case tag
    when "sale" then "#{property_type} for sale"
    when "rent" then "#{property_type} for rent"
    when "new" then "New #{property_type.downcase}"
    else property_type
    end
  end

  def self.budget_range(label)
    case label
    when "Under $500K" then 0..49_999_999
    when "$500K – $1M" then 50_000_000..100_000_000
    when "$1M – $3M" then 100_000_000..300_000_000
    when "$3M – $7M" then 300_000_000..700_000_000
    when "$7M+" then 700_000_000..Float::INFINITY
    when "Under $3K / mo" then 0..300_000
    when "$3K – $6K / mo" then 300_000..600_000
    when "$6K+ / mo" then 600_000..Float::INFINITY
    end
  end

  def tag_label
    case tag
    when "sale" then "For Sale"
    when "rent" then "For Rent"
    when "new" then "New Home"
    else tag.titleize
    end
  end

  def full_address
    [ address, city, state, zip ].compact_blank.join(", ")
  end

  def feature_list
    Array(features).map { |f| f.to_s.strip }.reject(&:blank?).uniq
  end

  # Zillow-style Facts & features: group headers → category headings → bullet rows.
  # Uses first-class attributes plus heuristic buckets for flat BOK amenity strings.
  def facts_and_features_groups
    Taxonomy.build(self)
  end

  def gallery_image_urls
    urls = Array(image_urls).map { |u| u.to_s.strip }.reject(&:blank?)
    primary = self[:image_url].presence
    urls = [ primary ] if urls.empty? && primary
    urls = ([ primary ] + urls).compact if primary && !urls.include?(primary)
    urls.uniq
  end

  def display_price(currency: Current.currency)
    MoneyDisplay.format(price_cents, currency: currency, rent: tag == "rent")
  end

  # Always formats in BASE_CURRENCY for persisted `price_label` snapshots.
  def format_price
    MoneyDisplay.format(price_cents, currency: MoneyDisplay::BASE_CURRENCY, rent: tag == "rent")
  end

  def price_per_sqft_label(currency: Current.currency)
    MoneyDisplay.per_sqft(price_cents, sqft, currency: currency)
  end

  # e.g. "1.03 Acres" — Zillow-style lot size label
  def acreage_label
    value = acres.presence || derived_acres_from_lot
    return nil if value.blank? || value <= 0

    number = value == value.to_i ? value.to_i.to_s : format("%.2f", value).sub(/\.?0+$/, "")
    unit = value == 1 ? "Acre" : "Acres"
    "#{number} #{unit}"
  end

  def estimated_payment
    return nil unless tag == "sale" || tag == "new"

    MortgageEstimate.for_price_cents(price_cents)
  end

  def estimated_payment_label
    estimate = estimated_payment
    return nil unless estimate

    dollars = ActiveSupport::NumberHelper.number_to_delimited((estimate.monthly_cents / 100.0).round)
    "$#{dollars}/mo"
  end

  def days_on_estate
    # Inclusive calendar days (listed today → 1 day on TT)
    [(Time.zone.today - created_at.to_date).to_i + 1, 1].max
  end

  def days_on_estate_label
    days = days_on_estate
    unit = days == 1 ? "day" : "days"
    "#{days} #{unit} on TT"
  end

  def saves_count
    favorites.size
  end

  def record_view!(session)
    return if session.blank?

    viewed = Array(session[:viewed_property_ids]).map(&:to_i)
    return if viewed.include?(id)

    viewed = (viewed + [ id ]).last(80)
    session[:viewed_property_ids] = viewed
    increment!(:views_count)
  end

  def apply_lot_size_from_text!(*chunks)
    hit = LotSizeExtractor.call(chunks.compact.join("\n"))
    return false unless hit

    self.acres = hit.acres if acres.blank?
    self.lot_sqft = hit.lot_sqft if lot_sqft.blank?
    true
  end

  def to_param
    slug
  end

  def acres_derived_from_lot?
    return false if acres.blank? || lot_sqft.blank? || lot_sqft.to_i <= 0

    derived = (BigDecimal(lot_sqft.to_s) / LotSizeExtractor::SQFT_PER_ACRE).round(4)
    BigDecimal(acres.to_s).round(4) == derived
  end

  # Maps known BOK amenity strings into Interior / Exterior / Other categories.
  module Taxonomy
    CATEGORY_ORDER = {
      "Interior" => [
        "Bedrooms & bathrooms",
        "Kitchen",
        "Heating & cooling",
        "Laundry",
        "Interior features",
        "Furnishings",
        "Condition"
      ],
      "Exterior" => [
        "Lot",
        "Parking",
        "Outdoor living",
        "Security",
        "Community"
      ],
      "Other" => [
        "Utilities",
        "Accessibility",
        "Features"
      ]
    }.freeze

    GROUP_ORDER = CATEGORY_ORDER.keys.freeze

    FEATURE_PLACEMENT = {
      "Air Conditioning" => [ "Interior", "Heating & cooling" ],
      "Central Air Conditioning" => [ "Interior", "Heating & cooling" ],
      "Kitchen Appliances" => [ "Interior", "Kitchen" ],
      "Kitchen Island" => [ "Interior", "Kitchen" ],
      "Pantry" => [ "Interior", "Kitchen" ],
      "Powder Room" => [ "Interior", "Bedrooms & bathrooms" ],
      "Jacuzzi" => [ "Interior", "Bedrooms & bathrooms" ],
      "Built-in Closets" => [ "Interior", "Interior features" ],
      "Walk-in Closets" => [ "Interior", "Interior features" ],
      "Office Space" => [ "Interior", "Interior features" ],
      "Studio" => [ "Interior", "Interior features" ],
      "Attic" => [ "Interior", "Interior features" ],
      "Maid Quarters" => [ "Interior", "Interior features" ],
      "Annex" => [ "Interior", "Interior features" ],
      "Home Gym" => [ "Interior", "Interior features" ],
      "Wet Bar" => [ "Interior", "Interior features" ],
      "Smart Devices" => [ "Interior", "Interior features" ],
      "Cable TV" => [ "Interior", "Interior features" ],
      "Internet Access" => [ "Interior", "Interior features" ],
      "Laundry Area/Facility" => [ "Interior", "Laundry" ],
      "Unfurnished" => [ "Interior", "Furnishings" ],
      "Fully Furnished" => [ "Interior", "Furnishings" ],
      "Semi Furnished" => [ "Interior", "Furnishings" ],
      "Move in Ready" => [ "Interior", "Condition" ],
      "Recently Renovated" => [ "Interior", "Condition" ],
      "Freehold Land" => [ "Exterior", "Lot" ],
      "Leasehold Land" => [ "Exterior", "Lot" ],
      "Fully Fenced" => [ "Exterior", "Lot" ],
      "Partially Fenced" => [ "Exterior", "Lot" ],
      "T&C Approved" => [ "Exterior", "Lot" ],
      "Parking on Compound" => [ "Exterior", "Parking" ],
      "Covered Garage" => [ "Exterior", "Parking" ],
      "Patio" => [ "Exterior", "Outdoor living" ],
      "Private Pool" => [ "Exterior", "Outdoor living" ],
      "Shared Pool" => [ "Exterior", "Outdoor living" ],
      "Remote Gate" => [ "Exterior", "Security" ],
      "Gated Compound" => [ "Exterior", "Security" ],
      "Gated Community" => [ "Exterior", "Security" ],
      "Security Cameras" => [ "Exterior", "Security" ],
      "Security Patrols" => [ "Exterior", "Security" ],
      "Security Alarms" => [ "Exterior", "Security" ],
      "Pet Friendly" => [ "Exterior", "Community" ],
      "Kid Friendly" => [ "Exterior", "Community" ],
      "Water Heater" => [ "Other", "Utilities" ],
      "Water Tank" => [ "Other", "Utilities" ],
      "Water Pump" => [ "Other", "Utilities" ],
      "Electricity" => [ "Other", "Utilities" ],
      "3-Phase Electricity" => [ "Other", "Utilities" ],
      "Utilities included" => [ "Other", "Utilities" ],
      "Accessible" => [ "Other", "Accessibility" ]
    }.freeze

    module_function

    def build(property)
      buckets = Hash.new { |h, group| h[group] = Hash.new { |c, cat| c[cat] = [] } }

      add_structured!(buckets, property)
      property.feature_list.each { |feature| place_feature!(buckets, feature) }

      GROUP_ORDER.filter_map do |group_name|
        categories = CATEGORY_ORDER.fetch(group_name).filter_map do |category_name|
          items = buckets[group_name][category_name]
          next if items.blank?

          { name: category_name, items: items }
        end
        next if categories.empty?

        { name: group_name, categories: categories }
      end
    end

    def add_structured!(buckets, property)
      room_items = []
      room_items << "Bedrooms: #{property.beds}" if property.beds.present?
      room_items << "Bathrooms: #{property.baths}" if property.baths.present?
      buckets["Interior"]["Bedrooms & bathrooms"].concat(room_items) if room_items.any?

      lot_items = []
      if property.sqft.present?
        lot_items << "Building size: #{ActiveSupport::NumberHelper.number_to_delimited(property.sqft)} sqft"
      end
      lot_items << "Lot size: #{property.acreage_label}" if property.acreage_label.present?
      lot_items << "Type: #{property.property_type}" if property.property_type.present?
      buckets["Exterior"]["Lot"].concat(lot_items) if lot_items.any?
    end

    def place_feature!(buckets, feature)
      group, category = FEATURE_PLACEMENT[feature]
      if group
        buckets[group][category] << feature
      else
        buckets["Other"]["Features"] << feature
      end
    end
    private_class_method :add_structured!, :place_feature!
  end
  private_constant :Taxonomy

  private

  def derived_acres_from_lot
    return nil if lot_sqft.blank? || lot_sqft <= 0

    (BigDecimal(lot_sqft) / LotSizeExtractor::SQFT_PER_ACRE).round(4)
  end

  def sync_lot_size_fields
    if acres.present? && acres > 0 && lot_sqft.blank?
      self.lot_sqft = (BigDecimal(acres.to_s) * LotSizeExtractor::SQFT_PER_ACRE).round
    elsif lot_sqft.present? && lot_sqft > 0 && acres.blank?
      self.acres = derived_acres_from_lot
    end
  end

  def generate_slug
    return if slug.present?
    base = title.to_s.parameterize
    candidate = base
    n = 2
    while Property.exists?(slug: candidate)
      candidate = "#{base}-#{n}"
      n += 1
    end
    self.slug = candidate
  end

  def set_price_label
    self.price_label = format_price if price_cents.present? && (price_label.blank? || price_cents_changed?)
  end
end
