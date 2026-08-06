# Imports JSON produced by scripts/bok_gentle_listings_sync.py into Property records.
#
#   bin/rails bok:import[scripts/bok_sync_data/houses_last_month_….json]
#   bin/rails bok:import  # latest houses_last_month_*.json under scripts/bok_sync_data
#
class BokListingsImporter
  SITE_SUFFIX = /\s*[-–—]\s*My Bunch of Keys\s*\z/i
  DEFAULT_COORDS = [ 10.6549, -61.5019 ].freeze # Port of Spain centroid fallback

  # Theme/site chrome URLs that are not listing photos (mirrors bok_gentle_listings_sync.py).
  PLACEHOLDER_IMAGE_TOKENS = %w[
    /themes/
    share.jpg
    default.jpg
    default-halfpage-hero
    bok-icon.png
    logo.png
  ].freeze

  # Approximate community centroids for Trinidad map pins (not survey-grade).
  CITY_COORDS = {
    "maraval" => [ 10.7015, -61.5278 ],
    "port of spain" => [ 10.6549, -61.5019 ],
    "san fernando" => [ 10.2820, -61.4585 ],
    "chaguaramas" => [ 10.6885, -61.6382 ],
    "westmoorings" => [ 10.6755, -61.5585 ],
    "cascade" => [ 10.6850, -61.5120 ],
    "champs fleurs" => [ 10.6480, -61.4210 ],
    "diego martin" => [ 10.7205, -61.5580 ],
    "arima" => [ 10.6370, -61.2820 ],
    "tunapuna" => [ 10.6520, -61.3880 ],
    "st augustine" => [ 10.6410, -61.3990 ],
    "st. augustine" => [ 10.6410, -61.3990 ],
    "st joseph" => [ 10.6530, -61.4150 ],
    "st. joseph" => [ 10.6530, -61.4150 ],
    "curepe" => [ 10.6360, -61.4020 ],
    "san juan" => [ 10.6460, -61.4460 ],
    "barataria" => [ 10.6440, -61.4600 ],
    "woodbrook" => [ 10.6630, -61.5240 ],
    "st ann's" => [ 10.6850, -61.5150 ],
    "st anns" => [ 10.6850, -61.5150 ],
    "belmont" => [ 10.6620, -61.5050 ],
    "glencoe" => [ 10.6780, -61.5450 ],
    "goodwood park" => [ 10.6820, -61.5520 ],
    "valsayn" => [ 10.6300, -61.4100 ],
    "trincity" => [ 10.6350, -61.3500 ],
    "tobago" => [ 11.1800, -60.7400 ],
    "scarborough" => [ 11.1810, -60.7350 ],
    "couva" => [ 10.4220, -61.4670 ],
    "chaguanas" => [ 10.5160, -61.4110 ],
    "point fortin" => [ 10.1830, -61.6840 ],
    "princes town" => [ 10.2660, -61.3740 ],
    "sangre grande" => [ 10.5870, -61.1110 ],
    "mayaro" => [ 10.2910, -61.0060 ],
    "rio claro" => [ 10.3050, -61.1750 ],
    "freeport" => [ 10.4600, -61.4100 ],
    "carapichaima" => [ 10.4650, -61.4500 ],
    "santa cruz" => [ 10.7200, -61.4600 ],
    "maracas" => [ 10.7600, -61.4400 ],
    "las cuevas" => [ 10.7800, -61.4000 ],
    "petit valley" => [ 10.7000, -61.5500 ],
    "diamond vale" => [ 10.7050, -61.5650 ]
  }.freeze

  Result = Struct.new(:created, :updated, :skipped, :removed, :errors, keyword_init: true)

  def self.import!(path = nil, agent: nil)
    new(path, agent: agent).import!
  end

  def initialize(path = nil, agent: nil)
    @path = resolve_path(path)
    @agent = agent
  end

  def import!
    rows = JSON.parse(File.read(@path))
    raise ArgumentError, "Expected a JSON array in #{@path}" unless rows.is_a?(Array)

    feed_agent = @agent || import_feed_agent
    result = Result.new(created: 0, updated: 0, skipped: 0, removed: 0, errors: [])
    touched_agent_ids = Set.new([ feed_agent.id ])

    rows.each do |row|
      agent = resolve_listing_agent(row, feed_agent)
      touched_agent_ids << agent.id
      import_row(row, agent, result)
    end

    touched_agent_ids.each { |id| Agent.reset_counters(id, :properties) }
    result
  end

  private

  def resolve_path(path)
    return Pathname.new(path) if path.present?

    packaged = Rails.root.join("db/data/bok_listings.json")
    return packaged if packaged.exist?

    dir = Rails.root.join("scripts/bok_sync_data")
    latest = Dir.glob(dir.join("houses_last_month_*.json")).max_by { |f| File.mtime(f) }
    raise ArgumentError, "No db/data/bok_listings.json or houses_last_month_*.json under #{dir}" unless latest

    Pathname.new(latest)
  end

  # Feed-level agent retained as fallback when a row has no listing agent,
  # and as the explicit association when callers pass `agent:`.
  def import_feed_agent
    Agent.find_or_create_by!(email: "import@mybunchofkeys.com") do |a|
      a.name = "My Bunch of Keys"
      a.title = "Listing Feed"
      a.bio = "Listings synced from mybunchofkeys.com"
      a.phone = ""
      a.active = true
      a.show_on_homepage = false
      a.listings_count = 0
    end
  end

  def resolve_listing_agent(row, feed_agent)
    name = row["agent"].to_s.strip
    return feed_agent if name.blank?

    phone = row["agent_phone"].to_s.strip
    agency = row["agent_agency"].to_s.strip.presence || "Listing Agent"
    image = row["agent_image"].to_s.strip.presence
    email = import_email_for(name)

    agent = Agent.find_by(email: email)
    agent ||= Agent.find_by("LOWER(name) = ? AND phone = ?", name.downcase, phone) if phone.present?
    agent ||= Agent.find_by("LOWER(name) = ?", name.downcase)

    if agent
      updates = {}
      updates[:name] = name if agent.name != name
      updates[:title] = agency if agent.title != agency
      updates[:phone] = phone if phone.present? && agent.phone != phone
      updates[:image_url] = image if image.present? && agent.image_url != image
      agent.update!(updates) if updates.any?
      agent
    else
      Agent.create!(
        name: name,
        title: agency,
        email: email,
        phone: phone,
        image_url: image,
        bio: "Imported listing agent from mybunchofkeys.com",
        active: true,
        show_on_homepage: false,
        listings_count: 0
      )
    end
  end

  def import_email_for(name)
    slug = name.to_s.parameterize.presence || "agent"
    "#{slug}@import.mybunchofkeys.com"
  end

  def import_row(row, agent, result)
    bok_id = row["bok_id"].to_s.strip.presence
    source_url = row["url"].to_s.strip.presence
    if bok_id.blank? && source_url.blank?
      result.skipped += 1
      return
    end

    price_cents = parse_price_cents(row["price"])
    if price_cents.nil? || price_cents <= 0
      result.skipped += 1
      result.errors << "#{bok_id || source_url}: missing/invalid price"
      return
    end

    image_urls = resolve_image_urls(row)
    property = find_property(bok_id, source_url)

    if image_urls.empty?
      handle_unusable_images!(property, bok_id || source_url, result)
      return
    end

    attrs = build_attrs(row, agent, price_cents, image_urls)

    if property
      property.assign_attributes(attrs.except(:slug))
      if property.changed?
        property.save!
        result.updated += 1
      else
        result.skipped += 1
      end
    else
      Property.create!(attrs)
      result.created += 1
    end
  rescue ActiveRecord::RecordInvalid => e
    result.errors << "#{bok_id || source_url}: #{e.record.errors.full_messages.to_sentence}"
    result.skipped += 1
  end

  # Feed rows with no real listing photos must not stay public.
  # Existing rows are destroyed (statuses are sales lifecycle only — no draft/unpublished).
  def handle_unusable_images!(property, label, result)
    if property
      property.destroy!
      result.removed += 1
      result.errors << "#{label}: no usable images (removed)"
    else
      result.skipped += 1
      result.errors << "#{label}: no usable images"
    end
  end

  def resolve_image_urls(row)
    normalize_image_urls(row["images"].presence || row["image"])
  end

  def find_property(bok_id, source_url)
    scope = Property.all
    by_bok = bok_id.present? ? scope.find_by(bok_id: bok_id) : nil
    return by_bok if by_bok

    source_url.present? ? scope.find_by(source_url: source_url) : nil
  end

  def build_attrs(row, agent, price_cents, image_urls)
    title = clean_title(row["title"], row["url"])
    place = BokAddressResolver.call(row.merge("title" => title))
    primary = normalize_image_urls(row["image"]).first || image_urls.first

    {
      agent: agent,
      bok_id: row["bok_id"].presence,
      source_url: row["url"].presence,
      title: title,
      slug: slug_for(row),
      tag: map_tag(row),
      property_type: map_property_type(row),
      status: "active",
      address: place.address,
      city: place.city,
      state: place.state,
      zip: place.zip,
      price_cents: price_cents,
      beds: row["bedrooms"].to_s[/\d+/]&.to_i,
      baths: row["bathrooms"].to_s[/\d+/]&.to_i,
      sqft: parse_sqft(row["sqft"]),
      description: row["description"].to_s.strip.presence || title,
      image_url: primary,
      latitude: place.latitude,
      longitude: place.longitude,
      featured: false,
      features: normalize_features(row["features"]),
      image_urls: image_urls
    }.tap do |attrs|
      lot = LotSizeExtractor.call([ title, attrs[:description] ].join("\n"))
      if lot
        attrs[:acres] = lot.acres
        attrs[:lot_sqft] = lot.lot_sqft
      end
    end
  end

  def map_tag(row)
    intent = row["property_type"].to_s.downcase
    price = row["price"].to_s.downcase
    url = row["url"].to_s.downcase
    title = row["title"].to_s.downcase

    return "rent" if intent.include?("rent")
    return "rent" if price.include?("/ mth") || price.include?("/mth") || price.include?("per month")
    return "rent" if url.include?("for-rent") || title.include?("for rent")
    return "sale" if intent.include?("sale") || intent.include?("buy")

    "sale"
  end

  def map_property_type(row)
    style = row["property_style"].to_s.strip
    blob = "#{row['title']} #{row['description']} #{row['url']}".downcase

    case style
    when "House"
      return "Villa" if blob.include?("villa")
      return "Penthouse" if blob.include?("penthouse")
      return "Modern Home" if blob.include?("modern home")
      "House"
    when "Apartment/Townhouse"
      return "Townhouse" if blob.include?("townhouse") || blob.include?("town house") || blob.include?("town-house")
      "Apartment"
    when "Land"
      "Land"
    when "Commercial"
      "Commercial"
    when "Villa"
      "Villa"
    when "Penthouse"
      "Penthouse"
    else
      return "Townhouse" if blob.include?("townhouse")
      return "Apartment" if blob.include?("apartment")
      return "Land" if blob.match?(/\bland\b|\bacre/)
      return "Commercial" if blob.match?(/commercial|office|warehouse|retail|storage/)
      return "Villa" if blob.include?("villa")
      return "Penthouse" if blob.include?("penthouse")
      "House"
    end
  end

  def clean_title(raw, url)
    title = unescape(raw.to_s).gsub(SITE_SUFFIX, "").strip
    return title if title.present?

    path = URI.parse(url.to_s).path.to_s
    path.split("/").reject(&:blank?).last.to_s.tr("-", " ").titleize.presence || "BOK listing"
  rescue URI::InvalidURIError
    "BOK listing"
  end

  def address_from(title, city)
    BokAddressResolver.call("title" => title, "location" => city).address
  end

  def slug_for(row)
    from_url = row["url"].to_s[%r{/property/([^/]+)/?}i, 1]
    base = (from_url.presence || row["bok_id"].presence || row["title"]).to_s.parameterize
    base = "bok-listing" if base.blank?
    candidate = base
    n = 2
    while Property.exists?(slug: candidate)
      existing = Property.find_by(slug: candidate)
      break if existing && (existing.bok_id == row["bok_id"] || existing.source_url == row["url"])

      candidate = "#{base}-#{n}"
      n += 1
    end
    candidate
  end

  def parse_price_cents(raw)
    digits = raw.to_s.gsub(/[^\d.]/, "")
    return nil if digits.blank?

    (BigDecimal(digits) * 100).to_i
  end

  def parse_sqft(raw)
    digits = raw.to_s.gsub(/[^\d]/, "")
    digits.present? ? digits.to_i : nil
  end

  def coords_for(city)
    key = city.to_s.downcase.strip
    return CITY_COORDS[key] if CITY_COORDS.key?(key)

    match = CITY_COORDS.find { |name, _| key.include?(name) || name.include?(key) }
    match ? match.last : DEFAULT_COORDS
  end

  def unescape(text)
    CGI.unescapeHTML(text.to_s)
  end

  def normalize_features(raw)
    Array(raw).flat_map { |item| item.is_a?(String) ? item.split(/\s*;\s*/) : item }
      .map { |item| item.to_s.strip }
      .reject(&:blank?)
      .uniq
  end

  def normalize_image_urls(raw)
    Array(raw).flat_map { |item| item.is_a?(String) ? item.split(/\s*;\s*/) : item }
      .map { |item| item.to_s.strip }
      .reject(&:blank?)
      .reject { |url| placeholder_image?(url) }
      .uniq
  end

  def placeholder_image?(url)
    lower = url.to_s.downcase
    PLACEHOLDER_IMAGE_TOKENS.any? { |token| lower.include?(token) }
  end
end
