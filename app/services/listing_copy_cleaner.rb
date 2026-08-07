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

    # Mismatch / needs_review listings must not receive cleaned writes — unless
    # ListingCopyApplier deems the mismatches a safe size rematch.
    def skip?
      mismatches? || status == "needs_review"
    end

    def applyable?
      !skip? && status == "ok"
    end

    def mismatch_scenario
      rows = Array(verification&.dig("mismatches")).filter_map do |row|
        field = row["field"].presence || "field"
        note = row["note"].presence
        change = [ row["model"].inspect, row["from_description"].inspect ].join(" → ")
        [ "#{field}: #{change}", note ].compact.join(" — ")
      end
      notes = Array(verification&.dig("notes")).map(&:to_s).reject(&:blank?)
      (rows + notes).presence&.join(" | ") || "Copy review required (#{status})"
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
    verification = apply_grounding_guards!(cleaned, verification)
    verification = ensure_field_change_mismatches!(cleaned, verification)

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
          "description" => description_value_for(record_or_hash),
          "beds" => record_or_hash.beds,
          "baths" => record_or_hash.baths,
          "sqft" => record_or_hash.sqft,
          "lot_sqft" => record_or_hash.try(:lot_sqft),
          "acres" => record_or_hash.try(:acres),
          "property_type" => record_or_hash.property_type,
          "tag" => record_or_hash.tag,
          # Never trust BOK amenity chips — they routinely invent pools/gates/AC that
          # were never stated in the listing text. Features must be mined from copy.
          "features" => [],
          "bok_id" => record_or_hash.try(:bok_id),
          "source_url" => record_or_hash.try(:source_url),
          "price_label" => record_or_hash.try(:display_price)
        }.merge(attrs.slice(*(INPUT_KEYS - %w[features description])))
      else
        record_or_hash.deep_stringify_keys
      end

    INPUT_KEYS.index_with { |key| raw[key] }.merge(
      # Caller may pass features for tests, but the model always receives none.
      "features" => []
    )
  end

  def user_payload
    {
      allowed_property_types: ALLOWED_TYPES,
      allowed_tags: ALLOWED_TAGS,
      # Explicit flag so the model cannot rehydrate amenities from import chips.
      listing: @input.merge(
        "features" => [],
        "feature_source_rule" => "Mine features ONLY from title + description prose. Imported amenity chips are omitted on purpose."
      )
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
          "title": "bespoke SEO title, ~55–75 chars; benefit + place; no price; no FOR SALE/FOR RENT",
          "address": "real street or estate name only — never marketing title fragments",
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

      Anti-hallucination (hard rules — violate and mark needs_review):
      - Facts may ONLY come from listing.title and listing.description prose (plus structured
        beds/baths/sqft/lot/acres/type/tag fields as numeric constraints).
      - listing.features is intentionally empty. NEVER invent amenity chips from memory,
        common MLS templates, or photo guesses. If amenities are not written in the description
        or title, features must be [].
      - Forbidden to introduce unless the SOURCE description/title literally states them
        (synonyms count only when clearly equivalent): pool, gated, compound, air conditioning,
        A/C, closet, walk-in, garage, water heater, patio, balcony, gym, annex, furnished,
        semi-furnished, kid-friendly, pet-friendly, laundry, generator, solar, security.
      - "About the Region" / neighbourhood encyclopedia blurbs are NOT property facts. Do not
        treat region copy as evidence of amenities on this listing.
      - Sparse source (empty, "FOR SALE", or only region chrome): description must be a SHORT
        factual blurb from title + beds/baths/sizes/type only. Prefer 1–3 sentences. Do not
        pad with lifestyle marketing or invented finishes.
      - Address must never be marketing stubs: "Property for Sale", "House for Sale",
        "Home for Sale", "For Sale", "For Rent", "Charming 3", title fragments like
        "3 Bed House Orange Grove". Prefer a real street/neighbourhood or leave address blank.

      Other rules:
      - Title (SEO — critical):
          * Write a DISTINCT bespoke title from the payload — do NOT merely strip
            "Home for Sale" / prices from the import title and stop.
          * Preferred pattern: Benefit + place
            e.g. "Spacious TLC Family Home in Cleaver Heights, Arima"
            e.g. "Development Opportunity on Saddle Road, Maraval"
            e.g. "Renovated 3-Bed Retreat in Westmoorings"
          * Length target: about 55–75 characters (ok to land 50–80). Not a stub of only
            "Cleaver Heights, Arima" and not a keyword spam string.
          * Ground the benefit in SOURCE facts (beds, TLC/fixer language, annex, views,
            land size, freehold, starter home, dual living, etc.). Do not invent glamorous
            adjectives (“luxury”, “stunning”) unless the copy supports them.
          * Include the strongest place signal available: estate/street + locality
            (Cleaver Heights, Arima / Alexander Road, Vistabella). Prefer specificity over
            repeating only the city.
          * When beds/type are known, weaving them in is encouraged
            (“4-Bed Family Home…”) if it still fits the length window.
          * Forbidden in titles: prices, currency, TT$, NEG, FOR SALE, FOR RENT, emoji,
            agent names, phone numbers, ALL CAPS shouting.
          * Bad (too thin): "Cleaver Heights, Arima" | "Property for Sale" | "House in Maraval"
          * Good: "Spacious 4-Bed Family Home Needing TLC, Cleaver Heights Arima"
      - Address (hard rule — address field holds ONLY a postal/street/estate line):
          * Valid examples: "Alexander Road", "Hin Kin Road", "Daniel Drive", "Cleaver Heights",
            "#1 Saddle Road", "Pomme Rose Avenue".
          * INVALID — never copy these into address: listing titles, SEO titles, bed/bath counts,
            prices, "Property for Sale", "House for Sale", "Charming 3", "3 Bed House Orange Grove",
            "Beautiful 2 Storey House", "Home for Sale", benefit adjectives alone.
          * If no real street/estate can be mined from title/description/URL, set address to ""
            and keep the locality in city only. Prefer blank over a title fragment.
          * Do not repeat city/state/country inside address.
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
          * Lead with the property story, then key facts (beds/baths/sizes), then notable features
            ONLY when those features appear in the source description/title.
          * Strip emoji, ALL-CAPS yelling, price banners, contact spam, and "View More … Listings".
          * Keep factual content from the source; do not invent amenities.
          * Optional short "About the Region" paragraph only when useful; otherwise omit.
          * Output plain text only (no markdown headings, no bullet characters unless listing discrete room facts).
      - Features: max 12, title case, deduped, no prices; every item must be grounded in
        title/description wording. If unsure, omit.
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
    sanitize_address_field!(out)
    ground_features!(out)
    polish_weak_title!(out)
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

  # Address may only be a real street / estate line — never title or marketing copy.
  STREET_TOKENS = /\b(road|rd|street|st\.?|avenue|ave|drive|dr\.?|lane|ln|crescent|close|trace|boulevard|blvd|way|circle|court|ct|parkway|terrace|gardens?|estate|heights?|village)\b/i

  ADDRESS_STUB_PATTERNS = [
    /\A(?:turn|for\s+sale|for\s+rent|home\s+for\s+sale|house\s+for\s+sale|property\s+for\s+sale)\b/i,
    /\A(?:property|house|home|apartment|townhouse|land)\s+for\s+(?:sale|rent)\b/i,
    /\A(?:beautiful|lovely|charming|spacious|stunning|executive|affordable|grand|modern|newly|renovated)\b/i,
    /\Acharming\s+\d+\b/i,
    /\A\d+\s*bed(?:room)?\b/i,
    /\b\d+\s*bed(?:room)?s?\b/i,
    /\b(?:for\s+sale|for\s+rent|tt\$|neg(?:otiable)?)\b/i,
    /\A(?:house|home|apartment|townhouse|property|land)\z/i
  ].freeze

  def sanitize_address_field!(out)
    if out["address"].present? && !real_address_line?(out["address"], out)
      out["address"] = ""
    end

    if out["address"].blank?
      mined = mine_street_address(out)
      out["address"] = mined if mined.present? && real_address_line?(mined, out)
    end

    out["address"] = "" if out["address"].present? && !real_address_line?(out["address"], out)
    dedupe_address_city!(out)

    if out["address"].present? && out["city"].present? && out["address"].casecmp?(out["city"])
      out["address"] = ""
    end
  end

  def real_address_line?(address, out)
    value = address.to_s.strip
    return false if value.blank?
    return false if value.match?(/\b(?:for\s+sale|for\s+rent|tt\$|neg(?:otiable)?)\b/i)
    return false if marketing_title_fragment?(value, out)

    # Real street / estate tokens win (e.g. Executive Drive, Cleaver Heights).
    if value.match?(STREET_TOKENS) || value.match?(/\A#?\d+[A-Za-z]?\s+\p{L}/)
      return false if value.match?(/\b(?:\d+\s*bed|bedroom|for\s+sale|house\s+for|home\s+for|property\s+for)\b/i)

      return true
    end

    return false if ADDRESS_STUB_PATTERNS.any? { |rx| value.match?(rx) }
    return false if value.match?(/\b(?:bed|bath|sale|rent|house|home|apartment|townhouse|property|family|charming|beautiful|spacious|stunning)\b/i)

    city = out["city"].to_s.strip
    return false if city.present? && value.casecmp?(city)

    # Short bare estate/locality different from city (Hillsboro while city=Maraval).
    value.split.size <= 3 && value.match?(/\A[\p{L}#0-9][\p{L}0-9'’\- ]+\z/)
  end

  def marketing_title_fragment?(value, out)
    candidates = [ out["title"], @input["title"] ].map { |t| t.to_s.strip }.reject(&:blank?)
    return true if candidates.any? { |t| value.casecmp?(t) }

    producty = value.match?(/\b(?:bed|house|home|sale|charming|beautiful|property|bedroom)\b/i)
    return true if producty && !value.match?(STREET_TOKENS) && candidates.any? { |t| t.downcase.include?(value.downcase) }

    producty && !value.match?(STREET_TOKENS)
  end

  def mine_street_address(out)
    resolved = BokAddressResolver.call(
      {
        "title" => out["title"].presence || @input["title"],
        "location" => [ @input["address"], out["city"], @input["city"] ].compact_blank.join(", "),
        "url" => @input["source_url"]
      }
    )
    city = out["city"].presence || resolved.city.to_s
    candidate = resolved.address.to_s.strip
    return candidate if candidate.present? && real_address_line?(candidate, out.merge("city" => city))

    blob = [
      out["title"], @input["title"],
      strip_region_chrome(@input["description"].to_s),
      strip_region_chrome(out["description"].to_s)
    ].compact.join(" \n ")

    if (m = blob.match(/\b((?:#?\d+[A-Za-z]?\s+)?[A-Z][\w'’\-]+(?:\s+[A-Z][\w'’\-]+){0,3}\s+(?:Road|Rd|Street|St|Avenue|Ave|Drive|Dr|Lane|Ln|Crescent|Close|Trace|Boulevard|Blvd|Way|Gardens|Estate|Heights|Village))\b/))
      street = m[1].to_s.strip.sub(/\A(?:in|at|on|near)\s+/i, "")
      return street if real_address_line?(street, out)
    end

    nil
  end

  def polish_weak_title!(out)
    title = out["title"].to_s.strip
    return unless weak_seo_title?(title, out)

    out["title"] = build_grounded_seo_title(out)
  end

  def weak_seo_title?(title, out)
    return true if title.blank?

    place_bits = [ out["address"], out["city"], @input["city"], @input["address"] ]
      .map { |v| v.to_s.strip }
      .reject(&:blank?)
      .uniq
    normalized = title.downcase.gsub(/[^\p{L}\p{N}\s]/, " ").gsub(/\s+/, " ").strip
    place_only = place_bits.any? do |bit|
      bit_norm = bit.downcase.gsub(/[^\p{L}\p{N}\s]/, " ").gsub(/\s+/, " ").strip
      next false if bit_norm.length < 4

      normalized == bit_norm ||
        normalized == [ bit_norm, out["city"].to_s.downcase ].reject(&:blank?).uniq.join(" ") ||
        normalized == "#{bit_norm} #{out['state'].to_s.downcase}".strip
    end
    return true if place_only

    has_product = title.match?(
      /\b(?:bed|bedroom|bath|home|house|apartment|townhouse|land|lot|family|starter|renovat|tlc|fixer|view|annex|development|opportunit|retreat|estate)\b/i
    )
    # Thin place-ish titles without a clear product/benefit signal
    return true unless has_product
    # Short titles that lack locality lose SEO value — polish when under ~40 chars
    # and missing the city/estate already present on the listing.
    city = out["city"].to_s.strip
    return true if title.length < 40 && city.present? && !title.match?(/#{Regexp.escape(city)}/i)

    false
  end

  def build_grounded_seo_title(out)
    place = [ out["address"].presence, out["city"].presence ].compact_blank.uniq.join(", ")
    place = out["city"].presence || "Trinidad" if place.blank?

    benefit = grounded_title_benefit(out)
    type = out["property_type"].presence || "Home"
    beds = out["beds"]

    candidate =
      if benefit.present? && beds
        "#{benefit} #{beds.to_i}-Bed #{type} in #{place}"
      elsif benefit.present?
        "#{benefit} #{type} in #{place}"
      elsif beds
        "#{beds.to_i}-Bed #{type} in #{place}"
      else
        "#{type} in #{place}"
      end

    candidate = candidate.gsub(/\s{2,}/, " ").strip
    # Soft trim toward ~75 chars without cutting mid-word when possible
    if candidate.length > 78
      cut = candidate[0, 75]
      candidate = cut.sub(/\s+\S*\z/, "").strip
    end
    candidate
  end

  def grounded_title_benefit(out)
    blob = "#{@input['title']} #{strip_region_chrome(@input['description'].to_s)} #{out['description']}"
    return "Spacious TLC" if blob.match?(/\b(?:tlc|needs?\s+work|fixer|renovat(?:ion|e)|canvas for)\b/i)
    return "Renovated" if blob.match?(/\b(?:newly\s+)?renovat(?:ed|ion)|upgraded|modern(?:ised|ized)?\b/i)
    return "Development Opportunity" if blob.match?(/\b(?:development|town\s+and\s+country|apartments?\s+approv|redevelop)\b/i)
    return "Starter" if blob.match?(/\bstarter\b/i) || (out["beds"].to_i == 1)
    return "Dual Living" if blob.match?(/\b(?:annex|annexe|two\s+separate\s+houses|self[-\s]?contained)\b/i)
    return "Family" if out["beds"].to_i >= 3 || blob.match?(/\bfamily\b/i)
    return "Hillside" if blob.match?(/\b(?:hill|hillsboro|view of the)\b/i)

    nil
  end

  # Features may only echo wording present in the source title/description.
  def ground_features!(out)
    source = source_property_text
    grounded = Array(out["features"]).select { |feature| feature_grounded_in_source?(feature, source) }
    out["features"] = grounded.first(12)
  end

  def feature_grounded_in_source?(feature, source)
    tokens = feature.to_s.downcase.scan(/[a-z0-9]+/).reject { |t| t.length < 3 || %w[and the for with].include?(t) }
    return false if tokens.empty?

    # Require every meaningful token (or a known synonym) to appear in source property copy.
    tokens.all? { |token| source_mentions_amenity?(token, source) }
  end

  AMENITY_ALIASES = {
    "ac" => %w[ac a/c airconditioning air-conditioning conditioning],
    "conditioning" => %w[ac a/c airconditioning air-conditioning conditioning],
    "air" => %w[ac a/c airconditioning air-conditioning],
    "pool" => %w[pool swimming],
    "gated" => %w[gated gate compound],
    "compound" => %w[gated gate compound],
    "garage" => %w[garage carport],
    "patio" => %w[patio verandah veranda gallery],
    "balcony" => %w[balcony gallery],
    "closet" => %w[closet cupboard wardrobe],
    "closets" => %w[closet cupboard wardrobe],
    "laundry" => %w[laundry washer dryer],
    "gym" => %w[gym fitness],
    "annex" => %w[annex annexe],
    "furnished" => %w[furnished],
    "semi" => %w[semi-furnished semifurnished],
    "heater" => %w[heater],
    "generator" => %w[generator],
    "solar" => %w[solar],
    "security" => %w[security],
    "kid" => %w[kid children family],
    "pet" => %w[pet dog cat],
    "parking" => %w[parking park car]
  }.freeze

  def source_mentions_amenity?(token, source)
    candidates = AMENITY_ALIASES[token] || [ token ]
    candidates.any? do |c|
      needle = c.to_s.downcase.tr("-/", "")
      source.include?(needle) || source.match?(/\b#{Regexp.escape(c)}\b/i)
    end
  end

  def source_property_text
    @source_property_text ||= begin
      title = @input["title"].to_s
      body = strip_region_chrome(@input["description"].to_s)
      "#{title}\n#{body}".downcase.tr("-/", " ").gsub(/\s+/, " ")
    end
  end

  def strip_region_chrome(text)
    text.to_s
      .split(/\n?\s*About the Region\b/i, 2).first
      .to_s
      .gsub(/\bView More[^\n.]{0,80}Listings\b/i, "")
      .strip
  end

  def sparse_source_description?
    body = strip_region_chrome(@input["description"].to_s)
    cleaned = body
      .gsub(/\b(?:for\s+sale|for\s+rent|sale|rent)\b/i, "")
      .gsub(/[^\p{L}\p{N}\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
    words = cleaned.split
    return true if words.size < 8

    # Sale chrome leftovers without property facts
    has_property_fact = cleaned.match?(
      /\b(?:bed(?:room)?s?|bath(?:room)?s?|sq\.?\s*ft|sqft|acre|land|road|street|avenue|drive|kitchen|storey|story)\b/i
    )
    !has_property_fact && words.size < 20
  end

  HIGH_RISK_AMENITY_PATTERNS = [
    /\b(?:private\s+)?pools?\b/i,
    /\bgated(?:\s+community|\s+compound)?\b/i,
    /\b(?:air\s*conditioning|a\/c|\bac\b)\b/i,
    /\b(?:walk[-\s]?in\s+)?closets?\b/i,
    /\b(?:covered\s+)?garages?\b/i,
    /\bwater\s+heaters?\b/i,
    /\b(?:private\s+)?patios?\b/i,
    /\b(?:home\s+)?gyms?\b/i,
    /\b(?:semi[-\s]?)?furnished\b/i,
    /\bkid[-\s]?friendly\b/i,
    /\bpet[-\s]?friendly\b/i,
    /\blaundry\b/i,
    /\bgenerators?\b/i,
    /\bsolar\b/i,
    /\bbuilt[-\s]?in\s+closets?\b/i,
    /\bmove[-\s]?in\s+ready\b/i
  ].freeze

  def apply_grounding_guards!(cleaned, verification)
    notes = Array(verification["notes"]).map(&:to_s)
    mismatches = Array(verification["mismatches"])
    invented = invented_amenity_hits(cleaned["description"])

    if invented.any?
      cleaned["description"] = collapse_to_factual_blurb(cleaned) if sparse_source_description?
      cleaned["description"] = strip_ungrounded_amenity_sentences(cleaned["description"]) unless sparse_source_description?
      cleaned["features"] = []
      notes << "Stripped ungrounded amenities not present in source title/description: #{invented.join(', ')}"
      mismatches << {
        "field" => "description",
        "model" => "invented amenities",
        "from_description" => "not stated",
        "note" => "Removed hallucinated amenities (#{invented.join(', ')})"
      }
      verification["status"] = "needs_review"
      verification["confidence"] = [ verification["confidence"].to_f, 0.55 ].min
    elsif sparse_source_description?
      # Region chrome is not property copy — always replace with structured facts only.
      cleaned["description"] = collapse_to_factual_blurb(cleaned)
      cleaned["features"] = []
      notes << "Sparse source description — factual blurb only; amenities cleared"
      verification["status"] = "needs_review" unless %w[mismatch needs_review].include?(verification["status"])
      verification["confidence"] = [ verification["confidence"].to_f, 0.7 ].min
    end

    verification["notes"] = notes.uniq
    verification["mismatches"] = mismatches
    status = verification["status"].to_s
    unless %w[ok mismatch needs_review].include?(status)
      verification["status"] = mismatches.any? ? "mismatch" : "ok"
    end
    verification
  end

  TRACKED_DRIFT_FIELDS = %w[beds baths sqft lot_sqft acres property_type tag].freeze

  # Models sometimes bump values (4 → 4.5 baths) with status=ok and no mismatch row.
  # Any structured drift must be explicit so apply paths can skip + flag.
  def ensure_field_change_mismatches!(cleaned, verification)
    mismatches = Array(verification["mismatches"])
    noted_fields = mismatches.map { |row| row["field"].to_s }

    TRACKED_DRIFT_FIELDS.each do |field|
      before = normalize_drift_value(field, @input[field])
      after = normalize_drift_value(field, cleaned[field])
      next if before == after
      next if noted_fields.include?(field)

      mismatches << {
        "field" => field,
        "model" => before,
        "from_description" => after,
        "note" => "Silent #{field} change #{before.inspect} → #{after.inspect} without verification note"
      }
      noted_fields << field
    end

    verification["mismatches"] = mismatches
    if mismatches.any? && verification["status"] == "ok"
      verification["status"] = "mismatch"
    elsif mismatches.any? && !%w[mismatch needs_review].include?(verification["status"].to_s)
      verification["status"] = "mismatch"
    end
    verification
  end

  def normalize_drift_value(field, value)
    case field
    when "beds", "baths", "acres"
      return nil if value.nil? || value.to_s.strip.empty?

      number = Float(value)
      number == number.to_i ? number.to_i : number
    when "sqft", "lot_sqft"
      cast_integer(value)
    else
      value.to_s.strip.presence
    end
  rescue ArgumentError, TypeError
    value
  end

  def invented_amenity_hits(cleaned_description)
    HIGH_RISK_AMENITY_PATTERNS.filter_map do |rx|
      next unless cleaned_description.to_s.match?(rx)
      next if source_mentions_pattern?(rx)

      cleaned_description.to_s[rx].to_s.downcase.presence || "amenity"
    end.uniq
  end

  def source_mentions_pattern?(rx)
    raw = "#{@input['title']}\n#{strip_region_chrome(@input['description'].to_s)}"
    raw.match?(rx)
  end
  def strip_ungrounded_amenity_sentences(text)
    text.to_s.split(/(?<=[.!?])\s+/).reject { |sentence|
      HIGH_RISK_AMENITY_PATTERNS.any? { |rx| sentence.match?(rx) } &&
        invented_amenity_hits(sentence).any?
    }.join(" ").gsub(/\s{2,}/, " ").strip
  end

  def collapse_to_factual_blurb(cleaned)
    parts = []
    type = cleaned["property_type"].presence || "Property"
    city = cleaned["city"].presence
    address = cleaned["address"].presence
    place = [ address, city ].compact_blank.join(", ")

    opener = if place.present?
      "#{type} in #{place}."
    else
      "#{type} listing."
    end
    parts << opener

    facts = []
    facts << "#{cleaned['beds']} bedroom#{'s' unless cleaned['beds'].to_i == 1}" if cleaned["beds"]
    facts << "#{cleaned['baths']} bathroom#{'s' unless cleaned['baths'].to_f == 1}" if cleaned["baths"]
    facts << "#{cleaned['sqft'].to_fs(:delimited)} sq ft building" if cleaned["sqft"]
    facts << "#{cleaned['lot_sqft'].to_fs(:delimited)} sq ft land" if cleaned["lot_sqft"]
    facts << "#{cleaned['acres']} acre#{'s' unless cleaned['acres'].to_f == 1}" if cleaned["acres"]
    parts << "Listed as #{facts.to_sentence}." if facts.any?

    title = cleaned["title"].to_s.strip
    parts << "Listed as #{title}." if title.present? && !opener.include?(title) && facts.empty?

    parts.join(" ").strip
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
    return "Apartment" if value.match?(/\Aapartment\s+buildings?\z/i)
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

  def description_value_for(record_or_hash)
    if record_or_hash.respond_to?(:description_plain)
      record_or_hash.description_plain
    else
      record_or_hash.description.to_s
    end
  end
end
