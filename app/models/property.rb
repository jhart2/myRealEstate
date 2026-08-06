class Property < ApplicationRecord
  include ImageAttachable

  belongs_to :agent, optional: true, counter_cache: :listings_count
  has_many :favorites, dependent: :destroy
  has_many :favorited_by_users, through: :favorites, source: :user
  has_many :inquiries, dependent: :destroy

  TAGS = %w[sale rent new].freeze
  PROPERTY_TYPES = %w[House Apartment Villa Penthouse Commercial Modern\ Home].freeze
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

  def mappable?
    latitude.present? && longitude.present?
  end

  def map_price_label
    dollars = price_cents.to_f / 100.0
    if tag == "rent"
      dollars >= 1_000 ? "$#{(dollars / 1_000).round(1)}K" : "$#{dollars.to_i}"
    elsif dollars >= 1_000_000
      "$#{(dollars / 1_000_000).round(1)}M"
    elsif dollars >= 1_000
      "$#{(dollars / 1_000).round(0)}K"
    else
      "$#{dollars.to_i}"
    end
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

  def display_price
    price_label.presence || format_price
  end

  def format_price
    dollars = price_cents / 100.0
    if tag == "rent"
      "$#{ActiveSupport::NumberHelper.number_to_delimited(dollars.to_i)} / mo"
    else
      "$#{ActiveSupport::NumberHelper.number_to_delimited(dollars.to_i)}"
    end
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
