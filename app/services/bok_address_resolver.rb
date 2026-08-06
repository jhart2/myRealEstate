# Resolves address / city / state for BOK import rows and existing Property records.
# BOK often sends Location: "N/A" while locality lives in the title or URL slug.
class BokAddressResolver
  Result = Struct.new(:address, :city, :state, :zip, :latitude, :longitude, :notes, keyword_init: true)

  PLACEHOLDER = /\A(?:n\/?a|na|none|null|unknown|-)\z/i
  MARKETING_PREFIX = /\A(?:for\s+sale|for\s+rent|homes?\s+for\s+sale|home\s+for\s+sale|sale|rent)\b[\s:\-]*/i
  LOT_SUFFIX = /\bon\s+[\d,]+\s*(?:sq\.?\s*ft\.?|sf|sqft|acres?)(?:\s+land)?\z/i

  EXTRA_PLACES = [
    "christina gardens", "wellington gardens", "la pastora", "hilbury estate",
    "hilbury", "st. george", "st george", "palmiste", "phillipine", "debe",
    "point cumana", "pt. cumana", "pt cumana"
  ].freeze

  def self.known_places
    @known_places ||= (
      BokListingsImporter::CITY_COORDS.keys +
      TrinidadRegion::KEYWORDS.values.flatten +
      EXTRA_PLACES
    ).uniq.sort_by { |p| -p.length }.freeze
  end

  def self.call(row = nil, property: nil, **_ignored)
    row = {} if row.nil? && property
    new(row: row || {}, property: property).call
  end

  def self.dry_run(scope = Property.where.not(bok_id: nil))
    scope.find_each.filter_map do |property|
      next unless needs_repair?(property)

      proposed = call(property: property)
      current = {
        address: property.address.to_s,
        city: property.city.to_s,
        state: property.state.to_s,
        zip: property.zip.to_s
      }
      next if current[:address] == proposed.address &&
              current[:city] == proposed.city &&
              current[:state] == proposed.state &&
              current[:zip] == proposed.zip

      {
        id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        source_url: property.source_url,
        before: current.merge(full_address: format_address(current)),
        after: {
          address: proposed.address,
          city: proposed.city,
          state: proposed.state,
          zip: proposed.zip,
          full_address: format_address(
            address: proposed.address, city: proposed.city, state: proposed.state, zip: proposed.zip
          ),
          latitude: proposed.latitude,
          longitude: proposed.longitude
        },
        notes: proposed.notes
      }
    end
  end

  def self.needs_repair?(property)
    fields = [ property.address, property.city, property.state ]
    return true if fields.any? { |v| v.to_s.match?(/\bN\/A\b/i) || v.to_s.match?(PLACEHOLDER) }
    # Title was split on thousands-separator commas: "… on 16" from "16,910".
    return true if property.address.to_s.match?(/\bon\s+\d{1,3}\z/i)
    # Barbados (or other) listings imported with Trinidad as state.
    blob = "#{property.title} #{property.source_url}".downcase
    return true if blob.include?("barbados") && property.state.to_s.match?(/\Atrinidad\z/i)

    false
  end

  def self.format_address(parts)
    values = parts.is_a?(Hash) ? parts : parts.to_h
    [ values[:address], values[:city], values[:state], values[:zip] ]
      .map { |v| v.to_s.strip }
      .reject { |v| v.blank? || v.match?(PLACEHOLDER) }
      .uniq
      .join(", ")
  end

  def initialize(row: nil, property: nil)
    @row = row || {}
    @property = property
    @notes = []
  end

  def call
    title = clean_title
    url = source_url
    location = sanitize_location(raw_location)
    country = detect_country(title, url, location)
    city, street = infer_city_and_street(location, title, url, country)
    address = street.presence || street_from_title(title, city) || city.presence || country
    lat, lng = coords_for(city.presence || location.presence || country)

    Result.new(
      address: address,
      city: city.presence || country,
      state: country,
      zip: "",
      latitude: lat,
      longitude: lng,
      notes: @notes
    )
  end

  private

  def note(msg)
    @notes << msg
  end

  def raw_location
    @row["location"].presence || @property&.city
  end

  def clean_title
    raw = @row["title"].presence || @property&.title.to_s
    title = CGI.unescapeHTML(raw.to_s).gsub(/\s*[-–—]\s*My Bunch of Keys\s*\z/i, "").strip
    title.presence || "BOK listing"
  end

  def source_url
    @row["url"].presence || @property&.source_url.to_s
  end

  def sanitize_location(raw)
    parts = raw.to_s.split(/\s*,\s*/).map(&:strip).reject { |p| p.blank? || p.match?(PLACEHOLDER) }
    cleaned = parts.join(", ")
    note("stripped N/A from location") if raw.to_s.match?(/\bN\/A\b/i) && cleaned != raw.to_s.strip
    cleaned
  end

  def detect_country(*texts)
    blob = texts.compact.join(" ").downcase
    return "Barbados" if blob.include?("barbados")

    "Trinidad"
  end

  def infer_city_and_street(location, title, url, country)
    title_body = title_body(title)

    if location.present?
      parts = location.split(/\s*,\s*/)
      if parts.length >= 2
        city_candidate = parts.last
        if place?(city_candidate)
          note("city from location tail")
          return [ pretty_place(city_candidate), parts[0..-2].join(", ") ]
        end
      end

      # Entire cleaned location is a known place (e.g. "Debe")
      if place?(location) && !looks_like_street?(location)
        note("city from cleaned location")
        street = street_from_title(title, pretty_place(location))
        return [ pretty_place(location), street ]
      end

      # Street-only location — pull city from title/url
      if looks_like_street?(location) || parts.length == 1
        city = extract_place(title_body) || extract_place(title) || extract_place(url_text(url))
        if city
          note("city from title/url; street from location")
          return [ city, location ]
        end
      end

      city = extract_place(location)
      return [ city, nil ] if city
    end

    # Parse "Neighborhood, City[, Country]" from title body
    if title_body.include?(",")
      parts = title_body.split(/\s*,\s*/).map(&:strip)
        .reject { |p| p.blank? || p.match?(PLACEHOLDER) || p.match?(/\A\d+\z/) || p.match?(/\Abarbados\z/i) }
      if parts.length >= 2 && (place?(parts.last) || country == "Barbados")
        city_part = parts.last
        # When country is Barbados, last remaining part is the parish/city.
        if place?(city_part) || country == "Barbados"
          note("city/street from title body")
          return [ pretty_place(city_part), parts[0..-2].join(", ") ]
        end
      end
    end

    city = extract_place(title_body) || extract_place(title) || extract_place(url_text(url))
    if city
      note("city inferred from title/url (location blank/N/A)")
      return [ city, street_from_title(title, city) ]
    end

    note("fell back to country-level city")
    [ nil, nil ]
  end

  def title_body(title)
    # Prefer the clause after the first dash/pipe when the lead is marketing copy.
    # Never split on commas — titles use them in figures like "16,910".
    parts = title.split(/\s*[-–|]\s*/, 2).map(&:strip)
    lead = parts[0].to_s
    rest = parts[1].to_s
    body = lead.sub(MARKETING_PREFIX, "").strip
    body = rest if (body.blank? || lead.match?(/\A(?:for\s+sale|for\s+rent|homes?\s+for\s+sale)\z/i)) && rest.present?
    body = title if body.blank?
    body.sub(MARKETING_PREFIX, "").sub(LOT_SUFFIX, "").strip
  end

  def street_from_title(title, city)
    body = title_body(title)
    return nil if body.blank?
    return nil if city.present? && body.casecmp?(city)

    body = body.sub(LOT_SUFFIX, "").strip
    body = body.sub(/,?\s*#{Regexp.escape(city)}\s*\z/i, "").strip if city.present?
    # Drop leftover "HOME" / "HOUSE" when the city was embedded ("CHRISTINA GARDENS HOME")
    body = body.sub(/\b#{Regexp.escape(city)}\b/i, "").strip if city.present?
    body = body.gsub(/\s{2,}/, " ").gsub(/\s+,/, ",").strip
    return nil if body.blank? || body.match?(/\A(?:home|house|homes?|apartment|townhouse)\z/i)

    body
  end

  def url_text(url)
    slug = url.to_s[%r{/property/([^/]+)/?}i, 1].to_s
    slug.tr("-", " ")
  end

  def extract_place(text)
    hay = text.to_s.downcase
    hits = self.class.known_places.select do |place|
      hay.match?(/(?<![a-z])#{Regexp.escape(place)}(?![a-z])/)
    end
    return nil if hits.empty?

    # Prefer the place that appears latest in the string (usually the locality).
    pretty_place(hits.max_by { |place| hay.rindex(place) || -1 })
  end

  def place?(text)
    key = text.to_s.downcase.strip
    return false if key.match?(PLACEHOLDER)

    self.class.known_places.include?(key) || extract_place(text).present?
  end

  def looks_like_street?(text)
    text.to_s.match?(/\b(street|st\.|road|rd\.|drive|dr\.|avenue|ave\.|lane|ln\.|crescent|boulevard|blvd)\b/i)
  end

  def pretty_place(text)
    key = text.to_s.downcase.strip
    TrinidadRegion.titleize_place(key)
  rescue NoMethodError
    key.split.map(&:capitalize).join(" ")
  end

  def coords_for(city)
    key = city.to_s.downcase.strip
    coords = BokListingsImporter::CITY_COORDS
    return coords[key] if coords.key?(key)

    match = coords.find { |name, _| key.include?(name) || name.include?(key) }
    match ? match.last : BokListingsImporter::DEFAULT_COORDS
  end
end
