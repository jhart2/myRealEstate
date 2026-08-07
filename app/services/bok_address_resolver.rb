# Resolves address / city / state for BOK import rows and existing Property records.
# BOK often sends Location: "N/A" while locality/street lives in the title, URL, or description.
class BokAddressResolver
  Result = Struct.new(:address, :city, :state, :zip, :latitude, :longitude, :notes, keyword_init: true)

  PLACEHOLDER = /\A(?:n\/?a|na|none|null|unknown|-)\z/i
  MARKETING_PREFIX = /\A(?:for\s+sale|for\s+rent|homes?\s+for\s+sale|home\s+for\s+sale|sale|rent)\b[\s:\-]*/i
  MARKETING_LEAD = /\A(?:
      (?:house|home|homes?|apartment|townhouse|property|villa)?\s*(?:for\s+sale|for\s+rent|of\s+sale)|
      house\s+for\s+sale|home\s+for\s+sale|
      investment\s+propert(?:y|ies)|
      income\s+generating(?:\s+investment)?(?:\s+property)?|
      prime\s+propert(?:y|ies)|
      north\s+west\s+property(?:\s+for\s+sale)?|
      reduced
    )\b/ix
  PRICE_TAIL = /\s*[-–—]\s*(?:TTD\s*)?\$?[\d,.]+(?:m|k|tt|mtt)?\s*\z/i
  LOT_SUFFIX = /\bon\s+[\d,]+\s*(?:sq\.?\s*ft\.?|sf|sqft|acres?)(?:\s+land)?\z/i

  STREET_PATTERN = /
    \b(
      (?:\#?\d+[A-Za-z]?[^\S\n]+)?
      [A-Z][\w'’\-]+(?:[^\S\n]+[A-Z][\w'’\-]+){0,2}[^\S\n]+
      (?:Road|Rd\.?|Street|St\.?|Avenue|Ave\.?|Drive|Dr\.?|Lane|Ln\.?|
         Crescent|Close|Trace|Boulevard|Blvd\.?|Way|Gardens|Estate|
         Heights|Terrace|Hill|Shores|Court|Place)
    )\b
  /x

  LOCATED_ON = /
    \b(?:located\s+on|situated\s+(?:on|along)|along(?:\s+the)?)\s+
    ([A-Z][\w'’\-]+(?:\s+[A-Z][\w'’\-]+){0,4}
      (?:\s+(?:Road|Rd\.?|Street|St\.?|Avenue|Ave\.?|Drive|Dr\.?|Lane|Ln\.?|
               Crescent|Close|Trace|Boulevard|Blvd\.?|Way|Gardens|Estate|
               Heights|Terrace|Hill|Shores|Court|Place))?)
  /ix

  EXTRA_PLACES = [
    "christina gardens", "wellington gardens", "la pastora", "hilbury estate",
    "hilbury", "st. george", "st george", "palmiste", "phillipine", "debe",
    "point cumana", "pt. cumana", "pt cumana", "darrel spring", "darrell spring",
    "atlantic shores", "alyce glen", "la seiva", "valsayn north", "champ fleurs",
    "champs fleurs"
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
    return true if marketing_text?(property.address)
    # Title was split on thousands-separator commas: "… on 16" from "16,910".
    return true if property.address.to_s.match?(/\bon\s+\d{1,3}\z/i)
    blob = "#{property.title} #{property.source_url}".downcase
    return true if blob.include?("barbados") && property.state.to_s.match?(/\Atrinidad\z/i)
    return true if blob.include?("tobago") && property.state.to_s.match?(/\Atrinidad\z/i)

    false
  end

  def self.marketing_text?(value)
    v = value.to_s.strip
    return true if v.blank? || v.match?(PLACEHOLDER)
    return true if v.match?(MARKETING_LEAD)
    return true if v.match?(/\b(?:for\s+sale|for\s+rent|ideal\s+for|negotiable)\b/i) && !v.match?(STREET_PATTERN)
    # Title leftovers like "Renovated Commercial in …" — but not clean street lines.
    return true if !v.match?(STREET_PATTERN) &&
                   v.match?(/\b(?:commercial|residential|renovated|spacious|family)\b/i) &&
                   v.match?(/\b(?:in|on|at)\b/i) &&
                   v.split.size > 4
    return true if v.length > 72

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
    description = raw_description
    location = sanitize_location(raw_location)
    country = detect_country(title, url, location, description)
    city, street = infer_city_and_street(location, title, url, country, description)
    street = nil if self.class.marketing_text?(street)
    street = nil if street.present? && !looks_like_street?(street) && !street.match?(/\A#?\d/)
    mined = mine_street(title, url, description, city)
    street_candidates = [ mined, street ].compact.select { |c| looks_like_street?(c) || c.match?(/\A#?\d/) }
    address = street_candidates.max_by { |c| c.length }
    address ||= [ mined, street ].compact.find { |c| !self.class.marketing_text?(c) }
    address = city.presence || country if address.blank? || self.class.marketing_text?(address)
    city = prefer_city(city, title, url, description, address)
    # Never leave island/country labels in the city field.
    city = extract_place("#{title} #{url_text(url)} #{description.to_s[0, 400]}") if country_name?(city)
    city = country if city.blank?
    address = cleanup_street(address, city) || address
    address = city if address.blank? || self.class.marketing_text?(address)
    lat, lng = coords_for(city.presence || location.presence || country)

    Result.new(
      address: address,
      city: city.presence || country,
      state: country,
      zip: "",
      latitude: lat,
      longitude: lng,
      notes: @notes.uniq
    )
  end

  private

  def note(msg)
    @notes << msg
  end

  def raw_location
    @row["location"].presence || @property&.city
  end

  def raw_description
    return @row["description"] if @row["description"].present?
    return @property.description_plain if @property.respond_to?(:description_plain)

    @property&.description.to_s
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
    title, url, location, description = texts
    primary = [ title, url, location ].compact.join(" ")
    blob = [ primary, description ].compact.join(" ").downcase

    return "Barbados" if blob.include?("barbados")

    # "Trinidad and Tobago" is the country name — do not treat that as the island Tobago.
    primary_down = primary.downcase
    if primary_down.match?(/\btobago\b/) && !primary_down.match?(/trinidad\s+and\s+tobago/)
      return "Tobago"
    end

    "Trinidad"
  end

  def infer_city_and_street(location, title, url, country, description)
    body = title_body(title)

    if location.present?
      parts = location.split(/\s*,\s*/)
      if parts.length >= 2
        city_candidate = parts.last
        if place?(city_candidate)
          street = parts[0..-2].join(", ")
          # Prefer a community name (Darrel Spring) as city when last part is metro.
          if metro?(city_candidate) && place?(street) && !looks_like_street?(street)
            note("city from location community; metro demoted")
            return [ pretty_place(street), nil ]
          end
          note("city from location tail")
          return [ pretty_place(city_candidate), street ]
        end
      end

      if place?(location) && !looks_like_street?(location)
        note("city from cleaned location")
        city = pretty_place(location)
        return [ city, street_from_title(title, city) || mine_street(title, url, description, city) ]
      end

      if looks_like_street?(location) || parts.length == 1
        city = extract_place(body) || extract_place(title) || extract_place(url_text(url)) || extract_place(description)
        if city
          note("city from title/url/desc; street from location")
          return [ city, location ]
        end
      end

      city = extract_place(location)
      return [ city, nil ] if city
    end

    if body.include?(",")
      parts = body.split(/\s*,\s*/).map(&:strip)
        .reject { |p| p.blank? || p.match?(PLACEHOLDER) || p.match?(/\A\d+\z/) || p.match?(/\A(?:barbados|tobago|trinidad)\z/i) }
      if parts.length >= 2 && (place?(parts.last) || country == "Barbados")
        city_part = parts.last
        if place?(city_part) || country == "Barbados"
          note("city/street from title body")
          return [ pretty_place(city_part), parts[0..-2].join(", ") ]
        end
      end
    end

    city = extract_place(body) || extract_place(title) || extract_place(url_text(url)) || extract_place(description)
    if city
      note("city inferred from title/url/desc (location blank/N/A)")
      street = street_from_title(title, city) || mine_street(title, url, description, city)
      return [ city, street ]
    end

    note("fell back to country-level city")
    [ nil, nil ]
  end

  def title_body(title)
    # Prefer the clause after dash/pipe when the lead is marketing copy.
    # Never split on commas — titles use them in figures like "16,910".
    cleaned = title.to_s.sub(PRICE_TAIL, "").strip
    parts = cleaned.split(/\s*[-–|]\s*/, 2).map(&:strip)
    lead = parts[0].to_s
    rest = parts[1].to_s
    body = lead.sub(MARKETING_PREFIX, "").strip

    if rest.present? && (body.blank? || marketing_lead?(lead))
      body = rest.sub(PRICE_TAIL, "").strip
    end

    body = cleaned if body.blank?
    body.sub(MARKETING_PREFIX, "").sub(LOT_SUFFIX, "").sub(PRICE_TAIL, "").strip
  end

  def marketing_lead?(text)
    v = text.to_s.strip
    return true if v.match?(/\A(?:for\s+sale|for\s+rent|homes?\s+for\s+sale|home\s+for\s+sale)\z/i)
    return true if v.match?(MARKETING_LEAD)
    return true if v.match?(/\A(?:house|home|apartment|townhouse|property)\s+for\s+(?:sale|rent)\z/i)

    false
  end

  def street_from_title(title, city)
    body = title_body(title)
    return nil if body.blank?
    return nil if city.present? && body.casecmp?(city)
    return nil if self.class.marketing_text?(body)

    body = body.sub(LOT_SUFFIX, "").sub(PRICE_TAIL, "").strip
    body = body.sub(/,?\s*#{Regexp.escape(city)}\s*\z/i, "").strip if city.present?
    body = body.sub(/\b#{Regexp.escape(city)}\b/i, "").strip if city.present?
    body = body.gsub(/\s{2,}/, " ").gsub(/\s+,/, ",").strip
    return nil if body.blank? || body.match?(/\A(?:home|house|homes?|apartment|townhouse)\z/i)
    return nil if self.class.marketing_text?(body)

    body
  end

  def mine_street(title, url, description, city)
    blob = [ title_body(title), url_text(url), description.to_s[0, 1200] ].compact.join(" \n ")
    if (m = blob.match(LOCATED_ON))
      candidate = cleanup_street(m[1], city)
      if candidate.present?
        note("street mined from located-on phrase")
        return candidate
      end
    end

    candidates = blob.to_enum(:scan, STREET_PATTERN).map { Regexp.last_match[1] }
    cleaned = candidates
      .map { |c| cleanup_street(c.to_s.gsub(/\s+/, " "), city) }
      .compact
      .select { |c| c.split.size <= 5 }
    candidate = cleaned.min_by { |c| c.split.size }
    if candidate.present?
      note("street mined from title/url/description")
      return candidate
    end

    nil
  end

  def prefer_city(city, title, url, description, address)
    # Keep a concrete community already resolved from location.
    if city.present? && !metro?(city) && !country_name?(city) && place?(city) && city.to_s.split.size <= 3
      return city
    end

    candidates = [
      extract_place(title_body(title)),
      extract_place(url_text(url)),
      extract_place(description.to_s[0, 400]),
      extract_place(address.to_s),
      city
    ].compact.reject { |c| country_name?(c) }

    # Prefer specific community over metro / multi-community location blobs.
    specific = candidates.find { |c| !metro?(c) && c.to_s.split.size <= 3 }
    chosen = specific || candidates.find { |c| !metro?(c) } || candidates.first
    if chosen.present? && city.present? && !chosen.casecmp?(city.to_s)
      note("normalized city #{city.inspect} → #{chosen.inspect}")
    end
    chosen.presence || city
  end

  def country_name?(text)
    text.to_s.strip.match?(/\A(?:trinidad|tobago|barbados|trinidad and tobago)\z/i)
  end

  def cleanup_street(raw, city)
    value = raw.to_s.strip.sub(/\A(?:in|at|on|near|the)\s+/i, "")
    value = value.gsub(/\s+/, " ")
    value = value.sub(/,?\s*#{Regexp.escape(city)}\s*\z/i, "").strip if city.present?
    # Prefer the concrete street token span; drop trailing prose ("Road including the…").
    if (m = value.match(STREET_PATTERN))
      value = m[1].to_s.strip
    end
    value = value.sub(/\A(\d+[A-Za-z]?\s+)/, '#\1') if value.match?(/\A\d+[A-Za-z]?\s+\p{L}/) && raw.to_s.include?("#")
    return nil if value.blank? || self.class.marketing_text?(value)
    return nil if city.present? && value.casecmp?(city)
    return nil if country_name?(value)
    # Reject street lines polluted with prose.
    return nil if value.match?(/\b(?:including|featuring|with|comprising|ideal|potential|property|bedroom)\b/i)

    value
  end

  def self.address_quality(address, city = nil)
    a = address.to_s.strip
    return 0 if a.blank? || marketing_text?(a)
    return 1 if city.present? && a.casecmp?(city.to_s)
    return 0 if a.match?(/\b(?:including|featuring|with an office|potential|starter home)\b/i)
    return 4 if a.match?(/\A#?\d/) && a.match?(STREET_PATTERN)
    return 3 if a.match?(STREET_PATTERN)
    return 2 if a.split.size <= 4
    1
  end

  def url_text(url)
    slug = url.to_s[%r{/property/([^/]+)/?}i, 1].to_s
    slug.tr("-", " ")
  end

  def extract_place(text)
    hay = text.to_s.downcase
    hits = self.class.known_places.select do |place|
      next false if place.match?(/\A(?:trinidad|tobago|barbados)\z/)

      hay.match?(/(?<![a-z])#{Regexp.escape(place)}(?![a-z])/)
    end
    return nil if hits.empty?

    pretty_place(hits.max_by { |place| hay.rindex(place) || -1 })
  end

  def place?(text)
    key = text.to_s.downcase.strip
    return false if key.match?(PLACEHOLDER)

    self.class.known_places.include?(key) || extract_place(text).present?
  end

  def metro?(text)
    text.to_s.downcase.strip.match?(/\A(?:port of spain|scarborough|san fernando|chaguanas|arima)\z/)
  end

  def looks_like_street?(text)
    text.to_s.match?(STREET_PATTERN) ||
      text.to_s.match?(/\b(street|st\.?|road|rd\.?|drive|dr\.?|avenue|ave\.?|lane|ln\.?|crescent|boulevard|blvd\.?|terrace|shores|court|place)\b/i)
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
