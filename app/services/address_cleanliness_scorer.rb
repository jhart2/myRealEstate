require "json"

# Uses OpenAI to rank how "clean" / usable a property address is (0–100)
# and suggest a search query for Google Geocoding / Address Validation.
class AddressCleanlinessScorer
  class Error < StandardError; end

  Score = Struct.new(
    :score,
    :grade,
    :issues,
    :suggested_query,
    :has_street,
    :usable_for_map,
    :notes,
    :raw,
    keyword_init: true
  )

  SYSTEM = <<~PROMPT.freeze
    You rank real-estate listing addresses for data quality.
    Markets are mainly Trinidad & Tobago and Barbados (community names matter: Maraval, Westmoorings, Cascade, Holetown, etc.).

    Mine street/estate lines from title, URL slug, and description when the address field is marketing junk
    ("House For Sale", "Investment Property"). Prefer those mined lines in suggested_query.

    Score 0–100:
    - 90–100: real street line + community/city + country/island, usable as a postal/map pin
    - 70–89: community + weak/partial street, still mappable at neighbourhood level
    - 40–69: community/locality only, or marketing copy mixed into the address
    - 0–39: placeholder (N/A), title fragments, beds/baths promo, missing locality

    Return ONLY JSON with keys:
    score (int), grade (A|B|C|D|F), issues (string[]),
    suggested_query (string — best free-text for Google Geocoding),
    has_street (bool), usable_for_map (bool), notes (string).
  PROMPT

  def self.call(...)
    new.call(...)
  end

  def initialize(client: OpenaiClient.new)
    @client = client
  end

  def call(property = nil, address: nil, city: nil, state: nil, zip: nil, title: nil, source_url: nil, description: nil)
    raise Error, "OPENAI_API_KEY is not set" unless @client.configured?

    parts = if property
      {
        address: property.address,
        city: property.city,
        state: property.state,
        zip: property.zip,
        title: property.title,
        source_url: property.source_url,
        description_excerpt: property.description.to_s[0, 1200],
        full_address: property.try(:full_address),
        mined_hint: BokAddressResolver.call(property: property).then { |r|
          { address: r.address, city: r.city, state: r.state, notes: r.notes }
        }
      }
    else
      {
        address: address,
        city: city,
        state: state,
        zip: zip,
        title: title,
        source_url: source_url,
        description_excerpt: description.to_s[0, 1200],
        full_address: [ address, city, state, zip ].compact_blank.join(", ")
      }
    end

    response = @client.chat(
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM },
        { role: "user", content: JSON.generate(parts) }
      ]
    )

    data = JSON.parse(response[:content])
    Score.new(
      score: data["score"].to_i.clamp(0, 100),
      grade: data["grade"].to_s.upcase.presence || letter_for(data["score"].to_i),
      issues: Array(data["issues"]).map(&:to_s),
      suggested_query: data["suggested_query"].to_s.strip.presence || parts[:full_address],
      has_street: !!data["has_street"],
      usable_for_map: !!data["usable_for_map"],
      notes: data["notes"].to_s,
      raw: data
    )
  rescue JSON::ParserError => e
    raise Error, "OpenAI returned invalid JSON: #{e.message}"
  rescue OpenaiClient::Error => e
    raise Error, e.message
  end

  private

  def letter_for(score)
    case score
    when 90..100 then "A"
    when 70..89 then "B"
    when 40..69 then "C"
    when 20..39 then "D"
    else "F"
    end
  end
end
