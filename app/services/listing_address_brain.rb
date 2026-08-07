require "json"

# Scrape/import "brain": cheap heuristics first, OpenAI only when the document is weak,
# Google only when we still need a usable street/coords. Used by BokListingsImporter.
#
#   ListingAddressBrain.enrich(row)
#
# Disable with BOK_ADDRESS_BRAIN=0. Requires OPENAI_API_KEY (Google optional).
class ListingAddressBrain
  class Error < StandardError; end

  Result = Struct.new(
    :address, :city, :state, :zip, :latitude, :longitude,
    :source, :weak, :notes, :score,
    keyword_init: true
  )

  EXTRACT_SYSTEM = <<~PROMPT.freeze
    Extract the best postal-style address for a Trinidad & Tobago / Barbados property listing.
    Prefer real street / estate / terrace lines from title, URL slug, location, or description.
    Never invent house numbers. Never keep marketing copy ("House For Sale", "Investment Property").
    Communities matter (Maraval, Petit Valley, Champs Fleurs, Darrel Spring, Woodbrook, etc.).
    If only a community is known, put that in city and leave address equal to the community or estate name.
    Return ONLY JSON keys:
      address, city, state (Trinidad|Tobago|Barbados), zip, suggested_query, confidence (0-100), notes
  PROMPT

  BATCH_SYSTEM = <<~PROMPT.freeze
    Extract postal-style addresses for Trinidad & Tobago / Barbados property listings.
    Prefer real street / estate / terrace lines from title, URL slug, location, or description.
    Never invent house numbers. Never keep marketing copy ("House For Sale", "Investment Property").
    Communities matter (Maraval, Petit Valley, Champs Fleurs, Darrel Spring, Woodbrook, etc.).
    state must be exactly one of: Trinidad, Tobago, Barbados.
    "Trinidad and Tobago" in text is the COUNTRY — only use Tobago when the listing is clearly on the island of Tobago.
    If only a community is known, set address to that community/estate name and city to the community.
    Return ONLY JSON: {"results":[{"id":"...","address":"...","city":"...","state":"...","zip":"","suggested_query":"...","confidence":0-100,"notes":"..."}]}
    Include one result per input id.
  PROMPT

  def self.enrich(...)
    new.enrich(...)
  end

  def self.enrich_batch(...)
    new.enrich_batch(...)
  end

  def self.weak_document?(row, heuristic = nil)
    new.weak_document?(row, heuristic)
  end

  def initialize(openai: OpenaiClient.new, google: GoogleAddressClient.new)
    @openai = openai
    @google = google
  end

  # Enrich many rows efficiently: one OpenAI call per batch, Google only when needed.
  # items: [{ id:, row:, heuristic: optional }, ...]
  # returns Hash id => Result
  def enrich_batch(items, batch_size: Integer(ENV.fetch("ADDRESS_BRAIN_BATCH", "12")))
    raise Error, "OPENAI_API_KEY is not set" unless @openai.configured?

    out = {}
    needs_ai = []

    items.each do |item|
      id = item[:id] || item["id"]
      row = stringify_keys(item[:row] || item["row"] || item)
      heuristic = item[:heuristic] || item["heuristic"] || BokAddressResolver.call(row)
      weak = weak_document?(row, heuristic)

      if !enabled? || !weak
        out[id] = refine_coords(
          wrap(heuristic, source: "heuristic", weak: weak, notes: Array(heuristic.notes))
        )
      else
        needs_ai << { id: id, row: row, heuristic: heuristic }
      end
    end

    needs_ai.each_slice(batch_size) do |slice|
      extracted_by_id = extract_batch_with_ai(slice)
      slice.each do |item|
        id = item[:id]
        heuristic = item[:heuristic]
        extracted = extracted_by_id[id] || extracted_by_id[id.to_s]
        notes = Array(heuristic.notes).dup

        unless extracted
          out[id] = refine_coords(
            wrap(heuristic, source: "heuristic", weak: true, notes: notes + [ "batch miss" ])
          )
          next
        end

        notes.concat(Array(extracted[:notes]))
        merged = merge_ai(heuristic, extracted)
        source = "openai"

        if needs_google?(merged) && @google.configured?
          resolved = @google.resolve(
            query: extracted[:suggested_query].presence || query_for(merged),
            region_hint: merged[:state]
          )
          if resolved
            merged = apply_google(merged, resolved, notes)
            source = "openai+google"
          else
            notes << "google unresolved"
          end
        end

        out[id] = refine_coords(
          Result.new(**merged, source: source, weak: true, notes: notes.uniq, score: extracted[:confidence])
        )
      end
    end

    out
  end

  def enrich(row, heuristic: nil)
    row = stringify_keys(row)
    heuristic ||= BokAddressResolver.call(row)
    notes = Array(heuristic.notes).dup
    weak = weak_document?(row, heuristic)

    unless enabled?
      return refine_coords(
        wrap(heuristic, source: "heuristic", weak: weak, notes: notes + [ "brain disabled" ])
      )
    end

    unless weak
      return refine_coords(wrap(heuristic, source: "heuristic", weak: false, notes: notes))
    end

    unless @openai.configured?
      return refine_coords(
        wrap(heuristic, source: "heuristic", weak: true, notes: notes + [ "openai unavailable" ])
      )
    end

    extracted = extract_with_ai(row, heuristic)
    notes.concat(Array(extracted[:notes]))
    merged = merge_ai(heuristic, extracted)
    source = "openai"

    if needs_google?(merged) && @google.configured?
      resolved = @google.resolve(
        query: extracted[:suggested_query].presence || query_for(merged),
        region_hint: merged[:state]
      )
      if resolved
        merged = apply_google(merged, resolved, notes)
        source = "openai+google"
      else
        notes << "google unresolved"
      end
    end

    refine_coords(
      Result.new(**merged, source: source, weak: true, notes: notes.uniq, score: extracted[:confidence])
    )
  rescue OpenaiClient::Error, GoogleAddressClient::Error => e
    refine_coords(wrap(heuristic, source: "heuristic", weak: true, notes: notes + [ e.message ]))
  end

  def weak_document?(row, heuristic = nil)
    row = stringify_keys(row)
    heuristic ||= BokAddressResolver.call(row)

    return true if truthy?(row["weak_address"])
    return true if Array(row["weak_reasons"]).any?
    return true if BokAddressResolver.marketing_text?(heuristic.address)
    return true if row["address"].present? && BokAddressResolver.marketing_text?(row["address"])
    return true if row["location"].to_s.match?(/\A(?:n\/?a|na|-)?\z/i)
    return true if multi_community_blob?(heuristic.city)
    return true if country_label?(heuristic.city)

    streetish = /(road|rd\.?|street|st\.?|drive|dr\.?|avenue|lane|terrace|shores|gardens|estate|court|crescent|heights|close)\b/i
    blob = [ row["title"], row["location"], row["description"].to_s[0, 500], heuristic.address ].join(" ")
    return true unless blob.match?(streetish)

    # Already have a concrete street-like address line — skip AI.
    return false if heuristic.address.to_s.match?(streetish) || heuristic.address.to_s.match?(/\A#?\d/)

    true
  end

  def country_label?(value)
    value.to_s.match?(/\A(?:trinidad|tobago|barbados)\z/i)
  end

  private

  def enabled?
    return false if ENV["BOK_ADDRESS_BRAIN"].to_s == "0"
    return true if ENV["BOK_ADDRESS_BRAIN"].to_s == "1"
    return false if Rails.env.test? && ENV["BOK_ADDRESS_BRAIN"].to_s != "1"

    @openai.configured?
  end

  def extract_with_ai(row, heuristic)
    payload = {
      title: row["title"],
      location: row["location"],
      url: row["url"],
      description_excerpt: row["description"].to_s[0, 1200],
      heuristic: {
        address: heuristic.address,
        city: heuristic.city,
        state: heuristic.state
      },
      scraper_flags: {
        weak_address: row["weak_address"],
        weak_reasons: row["weak_reasons"],
        has_street_signal: row["has_street_signal"]
      }
    }

    response = @openai.chat(
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: EXTRACT_SYSTEM },
        { role: "user", content: JSON.generate(payload) }
      ]
    )
    data = JSON.parse(response[:content])
    {
      address: data["address"].to_s.strip,
      city: data["city"].to_s.strip,
      state: normalize_state(data["state"], row),
      zip: data["zip"].to_s.strip,
      suggested_query: data["suggested_query"].to_s.strip,
      confidence: data["confidence"].to_i.clamp(0, 100),
      notes: [ "ai extract conf=#{data["confidence"]}", data["notes"].to_s.presence ].compact
    }
  end

  def extract_batch_with_ai(slice)
    payload = {
      listings: slice.map do |item|
        row = item[:row]
        heuristic = item[:heuristic]
        {
          id: item[:id],
          title: row["title"],
          location: row["location"],
          url: row["url"],
          description_excerpt: row["description"].to_s[0, 800],
          heuristic: {
            address: heuristic.address,
            city: heuristic.city,
            state: heuristic.state
          }
        }
      end
    }

    response = @openai.chat(
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: BATCH_SYSTEM },
        { role: "user", content: JSON.generate(payload) }
      ]
    )
    data = JSON.parse(response[:content])
    results = Array(data["results"])
    results.each_with_object({}) do |entry, memo|
      id = entry["id"]
      next if id.blank?

      row = slice.find { |s| s[:id].to_s == id.to_s }&.dig(:row) || {}
      memo[id] = {
        address: entry["address"].to_s.strip,
        city: entry["city"].to_s.strip,
        state: normalize_state(entry["state"], row),
        zip: entry["zip"].to_s.strip,
        suggested_query: entry["suggested_query"].to_s.strip,
        confidence: entry["confidence"].to_i.clamp(0, 100),
        notes: [ "ai batch conf=#{entry["confidence"]}", entry["notes"].to_s.presence ].compact
      }
    end
  end

  def merge_ai(heuristic, extracted)
    address = extracted[:address]
    address = heuristic.address if address.blank? || BokAddressResolver.marketing_text?(address)

    city = extracted[:city].presence || heuristic.city
    state = extracted[:state].presence || heuristic.state
    {
      address: address,
      city: city,
      state: state,
      zip: extracted[:zip].presence || heuristic.zip.to_s,
      latitude: heuristic.latitude,
      longitude: heuristic.longitude
    }
  end

  def needs_google?(merged)
    return false unless @google.configured?
    return true if BokAddressResolver.marketing_text?(merged[:address])
    return true if merged[:latitude].blank? || merged[:longitude].blank?
    # Street line parked on a CITY_COORDS / DEFAULT dump — must geocode.
    return true if PropertyStreetGeocoder.needs_refine?(merged)

    # Validate when we only have community-level heuristic coords.
    !merged[:address].to_s.match?(/\d/) && merged[:address].to_s.casecmp(merged[:city].to_s) != 0
  end

  # Cheap path: street addresses must not keep community-centroid pins.
  def refine_coords(result)
    return result unless PropertyStreetGeocoder.needs_refine?(result)

    refined = PropertyStreetGeocoder.refine(result, google: @google)
    return result unless refined

    notes = Array(result.notes) + [
      "street geocode conf=#{refined.confidence} (#{refined.location_type})"
    ]
    source =
      if result.source.to_s.include?("google")
        result.source
      else
        "#{result.source}+street_geocode"
      end

    Result.new(
      address: result.address,
      city: result.city,
      state: result.state,
      zip: result.zip,
      latitude: refined.latitude,
      longitude: refined.longitude,
      source: source,
      weak: result.weak,
      notes: notes.uniq,
      score: result.score
    )
  rescue GoogleAddressClient::Error => e
    Result.new(
      address: result.address,
      city: result.city,
      state: result.state,
      zip: result.zip,
      latitude: result.latitude,
      longitude: result.longitude,
      source: result.source,
      weak: result.weak,
      notes: Array(result.notes) + [ e.message ],
      score: result.score
    )
  end

  def apply_google(merged, resolved, notes)
    street = resolved.address.to_s.strip
    usable_street = street.present? &&
                    !street.casecmp?(merged[:city].to_s) &&
                    !plus_code?(street) &&
                    resolved.confidence.to_i >= 60 &&
                    (
                      resolved.location_type.to_s.match?(/ROOFTOP|RANGE_INTERPOLATED|PREMISE|STREET/i) ||
                      resolved.location_type.to_s == "GEOMETRIC_CENTER"
                    )

    if usable_street && (
         BokAddressResolver.marketing_text?(merged[:address]) ||
         BokAddressResolver.address_quality(merged[:address], merged[:city]) < 3
       )
      notes << "brain adopted Google street"
      merged[:address] = street
    end

    types = []
    if resolved.raw.is_a?(Hash)
      types = Array(resolved.raw["types"]).map(&:to_s) + Array(resolved.raw["_types"]).map(&:to_s)
    end
    if resolved.confidence.to_i >= 45 && resolved.latitude.present? && !types.include?("country")
      notes << "brain adopted Google coords (conf=#{resolved.confidence})"
      merged[:latitude] = resolved.latitude
      merged[:longitude] = resolved.longitude
    end

    if resolved.state.to_s.match?(/\A(Trinidad|Tobago|Barbados)\z/i)
      merged[:state] = resolved.state unless resolved.state == "Tobago" && merged[:state] == "Trinidad" &&
        !merged[:city].to_s.match?(/tobago/i)
    end

    merged
  end

  def query_for(merged)
    [ merged[:address], merged[:city], merged[:state] ].compact_blank.join(", ")
  end

  def wrap(heuristic, source:, weak:, notes:)
    Result.new(
      address: heuristic.address,
      city: heuristic.city,
      state: heuristic.state,
      zip: heuristic.zip,
      latitude: heuristic.latitude,
      longitude: heuristic.longitude,
      source: source,
      weak: weak,
      notes: notes.uniq,
      score: nil
    )
  end

  def normalize_state(value, row = {})
    raw = value.to_s.strip
    down = raw.downcase
    return "Barbados" if down.include?("barbados")

    blob = "#{row['title']} #{row['url']} #{row['location']} #{raw}".downcase
    if blob.match?(/\btobago\b/) && !blob.match?(/trinidad\s+and\s+tobago/)
      return "Tobago"
    end

    "Trinidad"
  end

  def multi_community_blob?(city)
    city.to_s.split.size >= 4
  end

  def plus_code?(value)
    value.to_s.match?(/\A[A-Z0-9]{2,}\+[A-Z0-9]{2,}\z/i)
  end

  def truthy?(value)
    value == true || value.to_s.match?(/\A(1|true|yes)\z/i)
  end

  def stringify_keys(row)
    row.to_h.transform_keys(&:to_s)
  end
end
