class Property < ApplicationRecord
  include ImageAttachable

  belongs_to :agent, optional: true, counter_cache: :listings_count
  has_many :favorites, dependent: :destroy
  has_many :favorited_by_users, through: :favorites, source: :user
  has_many :inquiries, dependent: :destroy
  has_rich_text :description
  has_many_attached :gallery_images

  # Plain text for OpenAI / matching; HTML for public render.
  def description_plain
    return "" unless description.present?

    description.to_plain_text.to_s
  end

  def description_html
    return "" unless description.present?

    description.body.to_html
  end

  TAGS = %w[sale rent new].freeze
  PROPERTY_TYPES = %w[House Apartment Townhouse Villa Penthouse Commercial Land Modern\ Home].freeze
  NON_RESIDENTIAL_TYPES = %w[Land Commercial].freeze
  RESIDENTIAL_TYPES = (PROPERTY_TYPES - NON_RESIDENTIAL_TYPES).freeze
  STATUSES = %w[active pending sold rented disabled].freeze
  STATUS_LABELS = {
    "active" => "Active",
    "pending" => "Pending",
    "sold" => "Sold",
    "rented" => "Rented",
    "disabled" => "Disabled"
  }.freeze
  # "New Homes" nav/search intent = listings created within this many days.
  NEW_LISTING_DAYS = 14
  # Full slider spectrum for search price histogram / dual-range control ($0 … $10M+).
  PRICE_HISTOGRAM_MAX_DOLLARS = 10_000_000
  PRICE_HISTOGRAM_BUCKETS = 40

  scope :active, -> { where(status: "active") }
  scope :disabled, -> { where(status: "disabled") }
  scope :featured, -> { active.where(featured: true) }
  scope :for_sale, -> { active.where(tag: "sale") }
  scope :for_rent, -> { active.where(tag: "rent") }
  scope :new_homes, -> { active.where("created_at >= ?", NEW_LISTING_DAYS.days.ago.beginning_of_day) }
  scope :by_type, ->(type) { where(property_type: type) if type.present? }
  scope :residential, -> { where(property_type: RESIDENTIAL_TYPES) }
  scope :copy_needs_review, -> { where(copy_needs_review: true) }

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

  def status_label
    STATUS_LABELS.fetch(status.to_s, status.to_s.titleize)
  end

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


  def self.new_listing_days
    NEW_LISTING_DAYS
  end

  def self.search(params = {})
    params = normalize_search_params(params)
    scope = active

    if params[:intent].to_s == "new"
      # "New Homes" means recently listed (sale or rent), not the construction `tag: new`.
      days = params[:days_max].presence&.to_i
      days = new_listing_days if days.nil? || days <= 0
      scope = scope.where("created_at >= ?", days.days.ago.beginning_of_day)
    elsif params[:intent].present? && TAGS.include?(params[:intent])
      scope = scope.where(tag: params[:intent])
    end

    types = Array(params[:property_types]).map(&:presence).compact
    if types.empty? && params[:property_type].present? && params[:property_type] != "Any Type"
      types = [ params[:property_type] ]
    end
    types &= PROPERTY_TYPES
    scope = scope.where(property_type: types) if types.any?

    # Map viewport bounds win over text location (Zillow-style area search).
    # Ignore degenerate / uninitialized Leaflet bounds (0,0 box, NaN, inverted)
    # so a zero-size map cannot wipe the result list.
    if params.values_at(:north, :south, :east, :west).all?(&:present?) &&
        usable_map_bounds?(
          north: params[:north],
          south: params[:south],
          east: params[:east],
          west: params[:west]
        )
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

    # days_max for non-"new" intents; intent=new already applied the window above.
    if params[:days_max].present? && params[:intent].to_s != "new"
      scope = scope.where("created_at >= ?", params[:days_max].to_i.days.ago.beginning_of_day)
    end

    if params[:featured].to_s.in?(%w[1 true])
      scope = scope.where(featured: true)
    end

    sort = params[:sort].to_s
    sort = "newest" if sort.blank? && params[:intent].to_s == "new"

    # Use reorder so a prior ORDER BY (joins/includes) cannot leave featured/recency
    # ahead of the user's price sort.
    scope = case sort
    when "price_asc" then scope.reorder(price_cents: :asc)
    when "price_desc" then scope.reorder(price_cents: :desc)
    when "newest" then scope.reorder(created_at: :desc)
    else scope.reorder(featured: :desc, created_at: :desc)
    end

    scope
  end

  def self.normalize_search_params(params)
    hash =
      case params
      when ActionController::Parameters
        params.to_h
      when Hash
        params
      else
        params.respond_to?(:to_h) ? params.to_h : {}
      end
    hash.with_indifferent_access
  end
  private_class_method :normalize_search_params

  def self.in_bounds(north:, south:, east:, west:)
    where(latitude: south..north, longitude: west..east)
  end

  def self.usable_map_bounds?(north:, south:, east:, west:)
    values = [ north, south, east, west ].map { |v| Float(v) }
    n, s, e, w = values
    return false unless values.all?(&:finite?)
    return false if s >= n || w >= e
    return false if (n - s) < 1.0e-8 || (e - w) < 1.0e-8
    # Uninitialized Leaflet often reports a 0×0 box at the null island.
    return false if values.all? { |v| v.abs < 1.0e-9 }

    true
  rescue ArgumentError, TypeError
    false
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
      .residential
      .includes(:agent, image_attachment: :blob)
      .with_attached_gallery_images
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
      priceCents: price_cents.to_i,
      rent: tag == "rent",
      price: display_price,
      priceLabel: map_price_label,
      beds: beds.to_i,
      baths: baths.present? ? baths.to_f : 0,
      sqft: sqft,
      sqftLabel: sqft.to_i.positive? ? ActiveSupport::NumberHelper.number_to_delimited(sqft) : nil,
      address: full_address,
      tag: tag_label,
      statusLabel: listing_status_label,
      propertyType: property_type,
      lat: latitude&.to_f,
      lng: longitude&.to_f,
      # CDN / scraped cover — never Active Storage on search/map (avoids N+1 signing).
      image: listing_cover_url,
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

  # Bucket counts for active/searchable inventory matching non-price filters.
  # Price/budget filters are ignored so the chart stays useful while adjusting the range.
  def self.price_histogram(params = {}, buckets: PRICE_HISTOGRAM_BUCKETS, max_dollars: PRICE_HISTOGRAM_MAX_DOLLARS)
    buckets = buckets.to_i.clamp(8, 80)
    max_dollars = max_dollars.to_i
    max_dollars = PRICE_HISTOGRAM_MAX_DOLLARS if max_dollars <= 0
    max_cents = max_dollars * 100
    last_bucket = buckets - 1

    scoped_params = normalize_search_params(params).except(:price_min, :price_max, :budget, :sort)
    scope = search(scoped_params).unscope(:order)

    # Clamp with CASE (not scalar MIN/MAX): Postgres rejects 2-arg MIN(); this
    # project's SQLite build also lacks LEAST. Cast to BIGINT before multiply so
    # price_cents * buckets cannot overflow Postgres integer (seen at ~$10M×40).
    bucket_expr = sanitize_sql_array([
      <<~SQL.squish,
        CASE
          WHEN price_cents IS NULL OR price_cents < 0 THEN 0
          WHEN price_cents >= ? THEN ?
          WHEN CAST((CAST(price_cents AS BIGINT) * ?) / ? AS INTEGER) > ? THEN ?
          ELSE CAST((CAST(price_cents AS BIGINT) * ?) / ? AS INTEGER)
        END
      SQL
      max_cents,
      last_bucket,
      buckets,
      max_cents,
      last_bucket,
      last_bucket,
      buckets,
      max_cents
    ])

    # Guard: SQLite integer division can still yield `buckets` for edge cents —
    # clamp again in Ruby when packing.
    counts = Array.new(buckets, 0)
    scope.unscope(:select)
         .group(Arel.sql(bucket_expr))
         .count
         .each do |bucket, count|
           index = bucket.to_i.clamp(0, last_bucket)
           counts[index] += count.to_i
         end
    counts
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
    BokAddressResolver.format_address(address: address, city: city, state: state, zip: zip)
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
    urls = Array(image_urls).filter_map { |u| self.class.normalize_gallery_url(u) }
    primary = self.class.normalize_gallery_url(self[:image_url]).presence
    urls = [ primary ] if urls.empty? && primary
    urls = ([ primary ] + urls).compact if primary && !urls.include?(primary)
    urls.uniq
  end

  # Clean download title: "<slug>-<1-based-index>.<ext>"
  def gallery_download_filename(index)
    idx = index.to_i
    ext =
      if (image = hosted_gallery_images[idx])
        image.blob.filename.extension.presence
      end
    ext = ext.to_s.downcase.presence || "jpg"
    base = slug.to_s.presence || title.to_s.parameterize.presence || "listing"
    "#{base}-#{idx + 1}.#{ext}"
  end

  # Percent-encode path (e.g. U+202F in BOK screenshot filenames) for valid HTTP URLs.
  def self.normalize_gallery_url(url)
    raw = url.to_s.strip
    return "" if raw.blank?

    uri = Addressable::URI.parse(raw)
    return raw if uri.nil? || uri.scheme.blank?

    uri.normalize.to_s
  rescue Addressable::URI::InvalidURIError, ArgumentError, TypeError
    raw
  end

  # Identity key for matching CDN URLs to blob source_url metadata.
  def self.gallery_url_identity(url)
    normalized = normalize_gallery_url(url)
    Addressable::URI.unescape(normalized).to_s
      .strip
      .downcase
      .sub(/\?.*\z/, "")
      .delete_suffix("/")
  rescue Addressable::URI::InvalidURIError, ArgumentError, TypeError
    url.to_s.strip.downcase.sub(/\?.*\z/, "").delete_suffix("/")
  end

  # Only serve blobs that live on the configured Active Storage service
  # (skip local-disk leftovers that 404 on Cloud Run).
  def self.blob_displayable?(blob)
    return false unless blob

    blob.service_name.to_s == Rails.configuration.active_storage.service.to_s
  end

  # Cover for search index / map markers: column CDN URLs only (no Active Storage).
  # Show/lightbox still use display_image_url / display_gallery_image_urls for enhanced blobs.
  def listing_cover_url
    gallery_image_urls.first.presence || self[:image_url].presence
  end

  # Hosted gallery blobs ordered to match scraper's gallery URL list.
  # Falls back to attachment order when metadata mapping is incomplete.
  def hosted_gallery_images
    attachments = gallery_attachments_with_blobs.select { |img| self.class.blob_displayable?(img.blob) }
    return [] if attachments.empty?

    by_source = {}
    attachments.each do |img|
      PropertyGalleryIngestor.source_urls_for(img.blob).each do |src|
        by_source[self.class.gallery_url_identity(src)] ||= img
      end
    end
    ordered = gallery_image_urls.filter_map { |url| by_source[self.class.gallery_url_identity(url)] }.uniq
    ordered.presence || attachments
  end

  def enhanced_gallery_images
    hosted_gallery_images.select { |img| self.class.blob_enhanced?(img.blob) }
  end

  # GALLERY_DISPLAY_MODE:
  #   hosted          — Active Storage only (default)
  #   enhanced_or_cdn — GCS only when blob metadata enhanced=true; else CDN URL
  #   enhanced_only   — enhanced Active Storage only (strict cutover)
  #   cdn             — always remote gallery_image_urls
  def self.gallery_display_mode
    ENV.fetch("GALLERY_DISPLAY_MODE", "hosted").to_s.strip.downcase
  end

  def self.blob_enhanced?(blob)
    ActiveModel::Type::Boolean.new.cast(blob&.metadata&.[]("enhanced"))
  end

  # Public UI gallery sources. Prefer hosted/enhanced per GALLERY_DISPLAY_MODE.
  def display_gallery_image_urls
    case self.class.gallery_display_mode
    when "cdn"
      gallery_image_urls
    when "enhanced_or_cdn"
      enhanced_or_cdn_gallery_urls
    when "enhanced_only"
      enhanced_gallery_images.map { |img| gallery_blob_path(img) }
    else
      hosted_gallery_images.map { |img| gallery_blob_path(img) }
    end
  end

  def display_image_url
    case self.class.gallery_display_mode
    when "cdn"
      listing_cover_url
    when "enhanced_or_cdn"
      enhanced_or_cdn_cover_url
    when "enhanced_only"
      cover = enhanced_gallery_images.first
      return gallery_blob_path(cover) if cover

      nil
    else
      cover = hosted_gallery_images.first
      return gallery_blob_path(cover) if cover
      return gallery_blob_path(image) if image.attached?

      nil
    end
  end

  def image_present?
    return gallery_image_urls.any? || self[:image_url].present? if %w[cdn enhanced_or_cdn].include?(self.class.gallery_display_mode)

    gallery_images.attached? || image.attached?
  end

  def gallery_ingest_needed?
    urls = gallery_image_urls
    return false if urls.empty?

    hosted = gallery_attachments_with_blobs.flat_map { |img| PropertyGalleryIngestor.source_urls_for(img.blob) }
    return true if hosted.empty?

    self.class.images_fingerprint(urls) != self.class.images_fingerprint(hosted)
  end

  def enqueue_gallery_ingest!
    return false unless gallery_ingest_needed?

    # Async gallery_ingest — sync/import never waits on download.
    PropertyImageIngestJob.perform_later(id)
    true
  end

  def self.images_fingerprint(urls)
    Array(urls)
      .map { |url| gallery_url_identity(url) }
      .reject(&:blank?)
      .uniq
      .sort
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
    [ (Time.zone.today - created_at.to_date).to_i + 1, 1 ].max
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
      room_items << "Bedrooms: #{property.beds}" if property.beds.present? && property.beds.to_i.positive?
      room_items << "Bathrooms: #{property.baths}" if property.baths.present? && property.baths.to_f.positive?
      buckets["Interior"]["Bedrooms & bathrooms"].concat(room_items) if room_items.any?

      lot_items = []
      if property.sqft.present? && property.sqft.to_i.positive?
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

  # Prefer preloaded attachments; never chain `.includes` on a loaded association
  # (that builds a fresh scope and re-queries once per listing — the index N+1).
  def gallery_attachments_with_blobs
    scope = gallery_images_attachments
    return scope.to_a if scope.loaded?

    scope.includes(:blob).to_a
  end

  def gallery_attachment_by_source_url
    attachments = gallery_attachments_with_blobs.select { |img| self.class.blob_displayable?(img.blob) }
    key = attachments.map(&:id)
    return @gallery_attachment_by_source_url if @gallery_attachment_by_source_url_key == key

    map = {}
    attachments.each do |img|
      PropertyGalleryIngestor.source_urls_for(img.blob).each do |src|
        map[self.class.gallery_url_identity(src)] ||= img
      end
    end
    @gallery_attachment_by_source_url_key = key
    @gallery_attachment_by_source_url = map
  end

  def enhanced_or_cdn_cover_url
    urls = gallery_image_urls
    return self.class.normalize_gallery_url(self[:image_url]).presence if urls.empty?

    first = urls.first
    img = gallery_attachment_by_source_url[self.class.gallery_url_identity(first)]
    if img && self.class.blob_enhanced?(img.blob)
      gallery_blob_path(img)
    else
      first
    end
  end

  def enhanced_or_cdn_gallery_urls
    by_source = gallery_attachment_by_source_url

    gallery_image_urls.map do |url|
      img = by_source[self.class.gallery_url_identity(url)]
      if img && self.class.blob_enhanced?(img.blob)
        gallery_blob_path(img)
      else
        url
      end
    end
  end

  def gallery_blob_path(attachable)
    Rails.application.routes.url_helpers.rails_blob_path(attachable, only_path: true)
  end

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
