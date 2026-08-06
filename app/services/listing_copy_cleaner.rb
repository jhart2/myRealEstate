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
      2) Make list-card fields consistent with the description narrative.
      3) Verify structured facts against what the description actually says.

      Return ONLY valid JSON with this shape:
      {
        "cleaned": {
          "title": "short human title, no price, no FOR SALE/FOR RENT prefix",
          "address": "street / neighbourhood line only",
          "city": "single locality name",
          "state": "Trinidad" or "Tobago" or "Barbados",
          "zip": "",
          "description": "clean multi-paragraph listing description; keep factual content; drop site chrome like View More Region Listings; keep About the Region only if useful and concise",
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

      Rules:
      - Prefer facts stated in description when resolving conflicts; record mismatches instead of inventing.
      - Do not invent beds/baths/sqft/lot size — use null if unknown.
      - Title should match address/city tone and not contradict description.
      - Features: max 12, title case, deduped, no prices.
      - If input description is truncated/noisy, rewrite clearly without fabricating amenities.
      - Trinidad locale: use Trinidad English; keep TT place names.
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
    {
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
