# frozen_string_literal: true

require "json"

# Crafts alternate public-search queries when Photon/Nominatim/Overpass miss.
# Used only for unresolved street-worthy pins — never invents house numbers.
#
#   AddressQueryForge.new.call(address:, city:, state:, title:)
class AddressQueryForge
  class Error < StandardError; end

  SYSTEM = <<~PROMPT.freeze
    You help geocode Trinidad & Tobago / Barbados property listings for OSM/Photon.
    Given a weak or missing street match, propose 2-4 alternate search queries.
    Rules:
    - Keep the real street / estate / hill / trace / avenue tokens when present.
    - Try useful variants: without house numbers, alternate spellings (Phillipine/Philippine,
      Champ Fleurs/Champs Fleurs), community+island, estate without marketing words.
    - Never invent house numbers or streets that are not implied by the inputs.
    - Prefer queries that end with Trinidad and Tobago or Barbados.
    Return ONLY JSON: {"queries":["...","..."],"notes":"..."}
  PROMPT

  def initialize(openai: OpenaiClient.new)
    @openai = openai
  end

  def configured?
    @openai.configured?
  end

  def call(address:, city: nil, state: nil, title: nil, description: nil)
    unless configured?
      return {
        queries: heuristic_variants(address, city, state),
        notes: "openai_unconfigured",
        source: "heuristic"
      }
    end

    user = {
      address: address.to_s,
      city: city.to_s,
      state: state.to_s,
      title: title.to_s.truncate(160),
      description: description.to_s.truncate(400)
    }.to_json

    response = @openai.chat(
      messages: [
        { role: "system", content: SYSTEM },
        { role: "user", content: user }
      ],
      temperature: 0.1,
      response_format: { type: "json_object" }
    )

    parsed = JSON.parse(response[:content])
    queries = Array(parsed["queries"]).map { |q| q.to_s.strip }.reject(&:blank?).uniq
    queries = heuristic_variants(address, city, state) if queries.empty?
    {
      queries: queries.first(4),
      notes: Array(parsed["notes"]).join("; ").presence,
      source: "openai"
    }
  rescue OpenaiClient::Error, JSON::ParserError => e
    {
      queries: heuristic_variants(address, city, state),
      notes: "forge_fallback=#{e.message}",
      source: "heuristic"
    }
  end

  private

  def heuristic_variants(address, city, state)
    street = address.to_s.sub(/\A#?\d+[a-z]?\s+/i, "").strip
    city_s = city.to_s.strip
    country =
      case state.to_s.downcase
      when "barbados" then "Barbados"
      when "tobago" then "Tobago, Trinidad and Tobago"
      else "Trinidad and Tobago"
      end

    variants = []
    variants << [ street, city_s, country ].reject(&:blank?).join(", ")
    variants << [ street, country ].reject(&:blank?).join(", ")
    if city_s.match?(/champs?\s*fleurs/i)
      variants << [ street, "Champ Fleurs", country ].reject(&:blank?).join(", ")
    end
    if city_s.match?(/phil+ip+ine/i)
      variants << [ street, "Philippine", country ].reject(&:blank?).join(", ")
      variants << [ street, "Philipine", country ].reject(&:blank?).join(", ")
    end
    variants << [ street.gsub(/drive/i, "Dr"), city_s, country ].reject(&:blank?).join(", ") if street.match?(/drive/i)
    variants << [ street.gsub(/\save(nue)?\b/i, " Avenue"), city_s, country ].reject(&:blank?).join(", ") if street.match?(/\bave\b/i)
    variants.map { |q| q.gsub(/\s+/, " ").strip }.uniq.reject(&:blank?).first(4)
  end
end
