# Two-pass OpenAI enricher: turns plain listing copy into polished semantic HTML
# for Action Text. Isolated behind LISTING_COPY_RICH_HTML=1 — never runs in BOK sync
# unless that flag is set.
#
#   result = ListingDescriptionRichFormatter.call(property)           # dry: no write
#   result = ListingDescriptionRichFormatter.call(property, apply: true)
#
# Pass 1 — structure: outline sections (intro, features, location, lifestyle).
# Pass 2 — render: semantic HTML (h2/h3, ul/li, strong, p) that “pops” features.
#
class ListingDescriptionRichFormatter
  class Error < StandardError; end

  ALLOWED_TAGS = %w[
    div p br h2 h3 strong em ul ol li a
  ].freeze

  Result = Struct.new(
    :property, :input_plain, :structure, :html, :usage, :applied, :skipped, :error,
    keyword_init: true
  ) do
    def applied? = applied
    def skipped? = skipped
  end

  def self.enabled?
    !%w[0 false off no].include?(ENV.fetch("LISTING_COPY_RICH_HTML", "0").to_s.strip.downcase)
  end

  def self.call(property, client: OpenaiClient.new, apply: false)
    new(property, client: client, apply: apply).call
  end

  def initialize(property, client:, apply:)
    @property = property
    @client = client
    @apply = apply
  end

  def call
    unless self.class.enabled?
      return Result.new(
        property: @property, skipped: true, applied: false,
        error: "LISTING_COPY_RICH_HTML is not enabled (set to 1)"
      )
    end

    plain = @property.description_plain.to_s.strip
    if plain.blank?
      return Result.new(property: @property, skipped: true, applied: false, error: "blank description")
    end

    usage = {}
    structure, usage1 = structure_pass!(plain)
    usage[:structure] = usage1

    html_raw, usage2 = render_pass!(plain, structure)
    usage[:render] = usage2

    html = sanitize_html(html_raw)
    raise Error, "empty HTML from render pass" if html.blank?

    if @apply
      @property.update!(description: html)
      Result.new(
        property: @property.reload, input_plain: plain, structure: structure,
        html: html, usage: usage, applied: true, skipped: false
      )
    else
      Result.new(
        property: @property, input_plain: plain, structure: structure,
        html: html, usage: usage, applied: false, skipped: false
      )
    end
  rescue OpenaiClient::Error, Error, JSON::ParserError => e
    Result.new(property: @property, skipped: true, applied: false, error: e.message, usage: usage)
  end

  private

  def structure_pass!(plain)
    response = @client.chat(
      temperature: 0.2,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You structure Trinidad & Tobago real-estate listing descriptions for a later HTML polish pass.
            Return JSON only:
            {
              "sections": [
                { "id": "intro"|"highlights"|"features"|"outdoor"|"location"|"lifestyle"|"other",
                  "heading": "short display heading",
                  "summary": "1-2 sentence outline of what belongs here",
                  "bullet_candidates": ["short factual bullets pulled ONLY from source", "..."] }
              ],
              "tone_notes": "brief note on how to keep voice grounded"
            }
            Rules:
            - Use ONLY facts present in the source. Never invent amenities, views, or finishes.
            - Prefer a Features/Highlights section when the source lists amenities or property features.
            - Skip empty sections. 2–5 sections is ideal.
            - bullet_candidates must be verbatim or lightly trimmed from the source — no new claims.
          PROMPT
        },
        {
          role: "user",
          content: JSON.generate({
            title: @property.title,
            property_type: @property.property_type,
            city: @property.city,
            description: plain
          })
        }
      ]
    )

    parsed = JSON.parse(response[:content])
    [ parsed, response[:usage] ]
  end

  def render_pass!(plain, structure)
    response = @client.chat(
      temperature: 0.35,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You convert real-estate listing copy into polished semantic HTML for an Action Text / Trix editor.
            Return JSON only: { "html": "<div>...</div>" }

            Formatting convention (full polish):
            - Wrap everything in a single <div>.
            - Opening intro as one or two <p> paragraphs.
            - Section headings as <h2> or <h3> (Features / Highlights should feel feature-rich).
            - Amenity and feature lists as <ul><li>…</li></ul>; put the lead noun in <strong> when it helps scanability.
            - Keep body prose readable; do not turn the whole listing into a list.
            - Allowed tags only: div, p, br, h2, h3, strong, em, ul, ol, li, a.
            - No classes, styles, images, scripts, or tables.
            - Facts ONLY from the source description + provided structure outline. Never invent.

            Make Features / Highlights “pop”: clear heading, tight bullets, strong leads — still truthful.
          PROMPT
        },
        {
          role: "user",
          content: JSON.generate({
            title: @property.title,
            source_description: plain,
            structure: structure
          })
        }
      ]
    )

    parsed = JSON.parse(response[:content])
    html = parsed["html"].to_s
    [ html, response[:usage] ]
  end

  def sanitize_html(html)
    ActionController::Base.helpers.sanitize(
      html.to_s,
      tags: ALLOWED_TAGS,
      attributes: %w[href]
    ).to_s.strip
  end
end
