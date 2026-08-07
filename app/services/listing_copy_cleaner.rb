# Humanizes dirty BOK/import listing copy and verifies structured fields against
# the description. Returns cleaned values — does not write to the DB.
#
#   result = ListingCopyCleaner.call(property)
#   result = ListingCopyCleaner.call(title: "...", description: "...", beds: 3, ...)
#
#   result.cleaned      # => { "title" => ..., "description" => ..., ... }
#   result.verification # => { "status" => "ok"|"mismatch"|"needs_review", "mismatches" => [...] }
#   result.mismatches?  # => true/false
#
class ListingCopyCleaner
  class Error < StandardError; end

  ALLOWED_TYPES = Property::PROPERTY_TYPES
  ALLOWED_TAGS = Property::TAGS

  INPUT_KEYS = %w[
    title address city state zip description
    beds baths sqft lot_sqft acres
    property_type tag features
    bok_id source_url price_label
  ].freeze

  Result = Struct.new(:input, :cleaned, :verification, :raw_model_json, :usage, keyword_init: true) do
    def mismatches?
      Array(verification&.dig("mismatches")).any?
    end

    def status
      verification&.dig("status") || "unknown"
    end
  end

  def self.call(record_or_hash, client: OpenaiClient.new)
    new(record_or_hash, client: client).call
  end

  def initialize(record_or_hash, client:)
    @client = client
    @input = normalize_input(record_or_hash)
  end

  def call
    response = @client.chat(
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: user_payload.to_json }
      ],
      temperature: 0.2,
      response_format: { type: "json_object" }
    )

    parsed = parse_json(response[:content])
    cleaned = normalize_cleaned(parsed["cleaned"] || parsed)
    verification = normalize_verification(parsed["verification"])

    Result.new(
      input: @input,
      cleaned: cleaned,
      verification: verification,
      raw_model_json: parsed,
      usage: response[:usage]
    )
  end

  private

  def normalize_input(record_or_hash)
    raw =
      if record_or_hash.respond_to?(:attributes)
        attrs = record_or_hash.attributes
        {
          "title" => record_or_hash.title,
          "address" => record_or_hash.address,
          "city" => record_or_hash.city,
          "state" => record_or_hash.state,
          "zip" => record_or_hash.zip,
          "description" => record_or_hash.description,
          "beds" => record_or_hash.beds,
          "baths" => record_or_hash.baths,
          "sqft" => record_or_hash.sqft,
          "lot_sqft" => record_or_hash.try(:lot_sqft),
          "acres" => record_or_hash.try(:acres),
          "property_type" => record_or_hash.property_type,
          "tag" => record_or_hash.tag,
          "features" => record_or_hash.feature_list,
          "bok_id" => record_or_hash.try(:bok_id),
          "source_url" => record_or_hash.try(:source_url),
          "price_label" => record_or_hash.try(:display_price)
        }.merge(attrs.slice(*INPUT_KEYS))
      else
        record_or_hash.deep_stringify_keys
      end

    INPUT_KEYS.index_with { |key| raw[key] }.merge(
      "features" => Array(raw["features"]).map(&:to_s).map(&:strip).reject(&:blank?)
    )
  end

  def user_payload
    {
      allowed_property_types: ALLOWED_TYPES,
      allowed_tags: ALLOWED_TAGS,
      listing: @input
    }
  end

  def system_prompt
    <<~PROMPT
      You clean Trinidad & Tobago real-estate listing copy for TT Realty.

      Goals:
      1) Humanize dirty import text (BOK MLS noise, ALL CAPS, emoji spam, marketing filler,
         "FOR SALE -", price suffixes in titles, duplicated place names).
      2) Mine structured attributes from title + description so list cards stay informative.
      3) Make card fields consistent with the description narrative.
      4) Verify structured facts against what the copy actually says.

      Return ONLY valid JSON with this shape:
      {
        "cleaned": {
          "title": "short human title, no price, no FOR SALE/FOR RENT prefix; keep street when known",
          "address": "street / neighbourhood line only (do not repeat city)",
          "city": "single locality name",
          "state": "Trinidad" or "Tobago" or "Barbados",
          "zip": "",
          "description": "clean, well-formatted multi-paragraph listing description",
          "beds": number or null,
          "baths": number or null,
          "sqft": integer or null,
          "lot_sqft": integer or null,
          "acres": number or null,
          "property_type": one of the allowed_property_types,
          "tag": one of the allowed_tags,
          "features": ["short amenity labels"]
        },
        "verification": {
          "status": "ok" | "mismatch" | "needs_review",
          "confidence": 0.0 to 1.0,
          "mismatches": [
            {
              "field": "beds|baths|sqft|lot_sqft|acres|property_type|tag|address|city|title",
              "model": "value currently on the listing",
              "from_description": "value implied by description/title",
              "note": "brief reason"
            }
          ],
          "notes": ["optional short notes"]
        }
      }

      Attribute mining (critical):
      - Actively extract beds, baths, house/building sqft, lot_sqft, and acres from the title
        AND description whenever stated (e.g. "5,000 SQ. FT. OF LAND", "House Size: 3,500 sq ft",
        "4000 Sqft home", "11,500 Sqft land", "on 16,910 sq ft Land").
      - Distinguish building size vs land size:
          * Interior / house / floor / building area → sqft
          * Lot / land / freehold parcel / site area → lot_sqft (also acres when given)
      - NEVER clear sqft just because the imported value was wrong. Reclassify:
          * If imported sqft was actually land, set lot_sqft to that figure and set sqft from any
            stated house size, or leave sqft as the previous house figure only if copy supports it.
          * If only land size is known, keep lot_sqft populated and set sqft to null only when no
            building area appears anywhere — then record a mismatch/note explaining why.
      - Prefer mined description/title facts over dirty imported numbers; always emit a mismatch
        when you change beds/baths/sqft/lot_sqft/acres.
      - Do not invent amenities or sizes that are not in the copy.

      Other rules:
      - Title: street + locality when street is known; no prices; no FOR SALE/FOR RENT prefixes.
      - Address and city are SEPARATE fields. Address must NEVER include the city, state, or country.
        Forbidden examples: "Hin Kin Road, Cunupia" when city is Cunupia; "Daniel Drive, Champs Fleurs"
        when city is Champs Fleurs. Correct: address="Hin Kin Road", city="Cunupia".
      - full display is composed later as "address, city, state" — any city already inside address
        will appear twice. Explicitly disallow duplicated localities in the address line.
      - City must be a real locality/neighbourhood (Maraval, Cunupia, Shorelands, …). Explicitly
        disallow using the state/country as city. Forbidden: city="Trinidad" with state="Trinidad"
        (produces "…, Trinidad, Trinidad"). Also forbid city in {Trinidad, Tobago, Barbados,
        Trinidad and Tobago}. If the imported city is a country, mine the true locality from
        title/description/URL (e.g. title "… in Shorelands" → city="Shorelands") and keep
        state as Trinidad/Tobago/Barbados only.
      - Description formatting (required):
          * Rewrite into clear TT English prose with short paragraphs separated by blank lines.
          * Lead with the property story, then key facts (beds/baths/sizes), then notable features.
          * Strip emoji, ALL-CAPS yelling, price banners, contact spam, and "View More … Listings".
          * Keep factual content from the source; do not invent amenities.
          * Optional short "About the Region" paragraph only when useful; otherwise omit.
          * Output plain text only (no markdown headings, no bullet characters unless listing discrete room facts).
      - Features: max 12, title case, deduped, no prices.
      - If description is truncated/noisy, rewrite clearly without fabricating facts.
      - Trinidad locale: Trinidad English; keep TT place names.
    PROMPT
  end

  def parse_json(content)
    JSON.parse(content)
  rescue JSON::ParserError
    # Models occasionally wrap JSON in fences despite json_object mode.
    stripped = content.to_s.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "")
    JSON.parse(stripped)
  rescue JSON::ParserError => e
    raise Error, "Failed to parse OpenAI JSON: #{e.message}"
  end

  def normalize_cleaned(raw)
    cleaned = raw.deep_stringify_keys
    out = {
      "title" => cleaned["title"].to_s.strip.presence || @input["title"],
      "address" => cleaned["address"].to_s.strip,
      "city" => cleaned["city"].to_s.strip,
      "state" => cleaned["state"].to_s.strip.presence || @input["state"],
      "zip" => cleaned["zip"].to_s.strip,
      "description" => cleaned["description"].to_s.strip.presence || @input["description"],
      "beds" => cast_number(cleaned["beds"]),
      "baths" => cast_number(cleaned["baths"]),
      "sqft" => cast_integer(cleaned["sqft"]),
      "lot_sqft" => cast_integer(cleaned["lot_sqft"]),
      "acres" => cast_number(cleaned["acres"]),
      "property_type" => sanitize_type(cleaned["property_type"]),
      "tag" => sanitize_tag(cleaned["tag"]),
      "features" => Array(cleaned["features"]).map { |f| f.to_s.strip }.reject(&:blank?).uniq.first(12)
    }
    preserve_size_chips!(out)
    dedupe_address_city!(out)
    fix_country_as_city!(out)
    fix_mangled_address_stub!(out)
    out
  end

  # If the model blanked building size without reclassifying land, keep usable card chips.
  def preserve_size_chips!(out)
    input_sqft = cast_integer(@input["sqft"])
    return if input_sqft.nil? || input_sqft <= 0
    return if out["sqft"].present?

    # Imported sqft was moved onto lot — that is a successful reclassify; leave building sqft null.
    return if out["lot_sqft"].present? && out["lot_sqft"] == input_sqft

    # Otherwise keep the prior chip rather than wiping the card empty.
    out["sqft"] = input_sqft
  end

  # Enforce address ≠ city. Strip trailing/embedded city, state, country from address.
  def dedupe_address_city!(out)
    address = out["address"].to_s.strip
    city = out["city"].to_s.strip
    state = out["state"].to_s.strip
    return if address.blank?

    rejectable = [ city, state, *COUNTRY_NAMES ]
      .map { |v| v.to_s.strip }
      .reject(&:blank?)
      .uniq

    parts = address.split(/\s*,\s*/).map(&:strip).reject(&:blank?)
    parts = parts.reject do |part|
      rejectable.any? { |token| part.casecmp?(token) }
    end

    # Also drop a trailing "… Cunupia" without comma when city is present.
    cleaned = parts.join(", ")
    if city.present? && !country_name?(city)
      cleaned = cleaned.sub(/,?\s*#{Regexp.escape(city)}\s*\z/i, "").strip
      cleaned = cleaned.sub(/\b#{Regexp.escape(city)}\b\s*\z/i, "").strip if parts.size <= 1
    end
    cleaned = cleaned.gsub(/\s{2,}/, " ").gsub(/\s+,/, ",").strip
    cleaned = cleaned.sub(/[,\s]+\z/, "")

    out["address"] = cleaned
  end

  COUNTRY_NAMES = [
    "Trinidad", "Tobago", "Barbados", "Trinidad and Tobago", "Trinidad & Tobago"
  ].freeze

  def country_name?(value)
    COUNTRY_NAMES.any? { |name| value.to_s.strip.casecmp?(name) }
  end

  # Disallow city=Trinidad / city=state duplicates; mine locality from title/copy.
  def fix_country_as_city!(out)
    city = out["city"].to_s.strip
    state = out["state"].to_s.strip.presence || "Trinidad"
    out["state"] = state

    bad_city = city.blank? || country_name?(city) || (state.present? && city.casecmp?(state))
    return unless bad_city

    mined = mine_locality_from_copy(out)
    if mined.present? && !country_name?(mined) && !mined.casecmp?(state)
      out["city"] = mined
      # If address was a mangled stub equal to leftover title crumbs, prefer locality as address.
      if out["address"].blank? || out["address"].match?(/\Aturn\b/i) || out["address"].casecmp?(mined)
        # keep street-like addresses; only replace obvious stubs
        out["address"] = mined if out["address"].blank? || out["address"].match?(/\Aturn\b/i)
      end
      dedupe_address_city!(out)
      return
    end

    # Last resort: don't leave country duplicated as city — clear city so full_address is address, state.
    out["city"] = "" if country_name?(city) || city.casecmp?(state)
  end

  def mine_locality_from_copy(out)
    blob = [
      out["title"], out["description"],
      @input["title"], @input["description"], @input["source_url"], out["address"], @input["address"]
    ].compact.join(" \n ")

    resolved = BokAddressResolver.call(
      {
        "title" => out["title"].presence || @input["title"],
        "location" => "",
        "url" => @input["source_url"]
      }
    )
    candidate = resolved.city.to_s.strip
    return candidate if valid_locality?(candidate)

    # Prefer the last "in/at/near Locality" phrase (usually the place, not marketing).
    mentions = blob.scan(/\b(?:in|at|near)\s+([A-Z][A-Za-z'’\-]+(?:\s+[A-Z][A-Za-z'’\-]+){0,2})\b/).flatten
    mentions.reverse_each do |mention|
      cleaned = mention.to_s
        .sub(/\s+(Home|House|Apartment|Townhouse|Property|Family)\b.*\z/i, "")
        .strip
      return cleaned if valid_locality?(cleaned)
    end

    nil
  end

  def valid_locality?(value)
    name = value.to_s.strip
    return false if name.blank? || country_name?(name)
    return false if name.split.size > 3
    return false if name.match?(/\b(Home|House|Apartment|Townhouse|Property|Family|Turn|Sale|Rent|Key)\b/i)

    true
  end

  # Drop obvious import stubs left in address once city is known.
  # Prefer blank address over copying city (avoids "Shorelands, Shorelands, Trinidad").
  def fix_mangled_address_stub!(out)
    address = out["address"].to_s.strip
    return unless address.match?(/\A(?:turn|for\s+sale|home\s+for\s+sale|house\s+for\s+sale)\b/i)

    out["address"] = ""
  end

  def normalize_verification(raw)
    verification = (raw || {}).deep_stringify_keys
    mismatches = Array(verification["mismatches"]).map do |row|
      row = row.deep_stringify_keys
      {
        "field" => row["field"].to_s,
        "model" => row["model"],
        "from_description" => row["from_description"],
        "note" => row["note"].to_s
      }
    end

    status = verification["status"].to_s
    status = mismatches.any? ? "mismatch" : "ok" unless %w[ok mismatch needs_review].include?(status)

    {
      "status" => status,
      "confidence" => verification["confidence"].to_f,
      "mismatches" => mismatches,
      "notes" => Array(verification["notes"]).map(&:to_s)
    }
  end

  def sanitize_type(value)
    value = value.to_s.strip
    return value if ALLOWED_TYPES.include?(value)
    return @input["property_type"] if ALLOWED_TYPES.include?(@input["property_type"].to_s)

    "House"
  end

  def sanitize_tag(value)
    value = value.to_s.strip.downcase
    return value if ALLOWED_TAGS.include?(value)
    return @input["tag"] if ALLOWED_TAGS.include?(@input["tag"].to_s)

    "sale"
  end

  def cast_integer(value)
    return nil if value.nil? || value.to_s.strip.empty?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def cast_number(value)
    return nil if value.nil? || value.to_s.strip.empty?

    number = Float(value)
    number == number.to_i ? number.to_i : number
  rescue ArgumentError, TypeError
    nil
  end
end
