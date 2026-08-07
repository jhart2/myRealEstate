# Two-pass OpenAI enricher: turns plain listing copy into polished semantic HTML
# for Action Text. Isolated behind LISTING_COPY_RICH_HTML=1 — never runs in BOK sync
# unless that flag is set.
#
#   result = ListingDescriptionRichFormatter.call(property)           # dry: no write
#   result = ListingDescriptionRichFormatter.call(property, apply: true)
#
# Pass 0 — detect source keyword hints (for packing bullets correctly).
# Pass 1 — structure into our bespoke headline taxonomy (OpenAI).
# Pass 2 — render semantic HTML with those exact headlines.
# Grounding strips invented amenities; bespoke headlines are always allowed.
#
class ListingDescriptionRichFormatter
  class Error < StandardError; end

  ALLOWED_TAGS = %w[
    div p br h2 h3 strong em ul ol li a
  ].freeze

  # Site-owned section titles — consistent across every polished listing.
  BESPOKE_HEADINGS = [
    { heading: "Property Features", id: "features", kinds: %w[features highlights] }.freeze,
    { heading: "Parking & Amenities", id: "parking", kinds: %w[parking amenities] }.freeze,
    { heading: "Location Highlights", id: "location", kinds: %w[location region neighborhood] }.freeze
  ].freeze

  BESPOKE_HEADING_LABELS = BESPOKE_HEADINGS.map { |h| h[:heading] }.freeze

  # Colon-labels that are contact/meta, not section headings.
  HEADING_BLOCKLIST = /\A(?:
    asking|price|sale|rent|call|whats?app|phone|email|contact|
    url|http|https|tel|fax|ref|mls|bok|id|sq\.?\s*ft|sqft|
    bedrooms?|bathrooms?|beds?|baths?
  )\z/ix

  # Labels that usually deserve an <h2>.
  HEADING_HINT = /
    feature|amenit|highlight|detail|parking|outdoor|interior|exterior|
    location|overview|specification|inclus|nearby|neighborhood|neighbourhood|
    about\s+the\s+region|the\s+region|community|compound
  /ix

  Result = Struct.new(
    :property, :input_plain, :heading_opportunities, :structure, :html,
    :usage, :applied, :skipped, :error, :grounding,
    keyword_init: true
  ) do
    def applied? = applied
    def skipped? = skipped
  end

  STOPWORDS = %w[
    a an the and or of to for with from that this these those into onto
    on in at by as is are was were be been being it its their our your
    each also just very more most other such only own same so than too
    can will would should may might must about over after before between
    out up down off then there when where which who what how each above
    feature features includes include including offer offers offering
  ].freeze

  def self.enabled?
    !%w[0 false off no].include?(ENV.fetch("LISTING_COPY_RICH_HTML", "0").to_s.strip.downcase)
  end

  def self.call(property, client: OpenaiClient.new, apply: false)
    new(property, client: client, apply: apply).call
  end

  def self.bespoke_heading?(heading)
    BESPOKE_HEADING_LABELS.any? { |label| label.casecmp?(heading.to_s.strip) }
  end

  def self.bespoke_opportunities
    BESPOKE_HEADINGS.map do |spec|
      {
        heading: spec[:heading],
        source_label: spec[:heading],
        offset: 0,
        kind: spec[:id],
        bespoke: true
      }
    end
  end

  # True when phrase is supported by source copy (not invented).
  # Guarantee: any content word ≥5 chars must appear in source, and either the
  # full phrase or a content bigram must be contiguous — so "tennis court" cannot
  # sneak in from unrelated words, and "Electronic gate: … electronic gate" keeps.
  def self.phrase_grounded?(phrase, source)
    needle = normalize_text(phrase)
    haystack = normalize_text(source)
    return false if needle.blank? || haystack.blank?
    return true if haystack.include?(needle) && needle.length >= 4

    # "Label: claim" bullets — ground if either side is supported.
    if phrase.to_s.match?(/[:—–-]/)
      parts = phrase.to_s.split(/[:—–-]/, 2).map(&:strip).reject(&:blank?)
      return true if parts.size >= 2 && parts.any? { |part| phrase_grounded?(part, source) }
    end

    words = content_words(needle)
    return false if words.empty?

    hay_tokens = haystack.split
    # Reject any distinctive word the source never said.
    return false if words.any? { |w| w.length >= 5 && !hay_tokens.include?(w) }

    if words.size == 1
      return hay_tokens.include?(words.first) && words.first.length >= 4
    end

    (0..(words.size - 2)).any? do |i|
      haystack.include?(words[i, 2].join(" "))
    end
  end

  def self.normalize_text(value)
    value.to_s.downcase
      .gsub(/&amp;/, " and ")
      .gsub(/[^a-z0-9\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
  end

  def self.content_words(normalized)
    normalized.split.reject { |w| w.length < 3 || STOPWORDS.include?(w) }
  end

  # Only our site taxonomy — BOK labels like "Key Features" get remapped/stripped.
  def self.heading_allowed?(heading, _source = nil, _opportunities = nil)
    bespoke_heading?(heading)
  end

  # Strip invented bullets / headings from HTML. Never invent amenities.
  def self.ground_html(html, source, opportunities: [])
    fragment = Nokogiri::HTML::DocumentFragment.parse(html.to_s)
    stripped_bullets = []
    stripped_headings = []

    fragment.css("li").each do |li|
      text = li.text.to_s.gsub(/\s+/, " ").strip
      next if phrase_grounded?(text, source)

      stripped_bullets << text
      li.remove
    end

    fragment.css("ul, ol").each do |list|
      list.remove if list.css("li").empty?
    end

    fragment.css("h2, h3").each do |node|
      heading = node.text.to_s.strip
      next if heading_allowed?(heading, source, opportunities)

      stripped_headings << heading
      # Keep following sibling content; just drop the invented label.
      node.remove
    end

    # Drop bespoke headings that ended up with no bullets/prose underneath.
    fragment.css("h2, h3").each do |node|
      next if section_has_content?(node)

      stripped_headings << "#{node.text.to_s.strip} (empty)"
      node.remove
    end

    {
      html: ActionController::Base.helpers.sanitize(
        fragment.to_html,
        tags: ALLOWED_TAGS,
        attributes: %w[href]
      ).to_s.strip,
      stripped_bullets: stripped_bullets,
      stripped_headings: stripped_headings
    }
  end

  def self.section_has_content?(heading_node)
    cursor = heading_node.next_element
    while cursor && !%w[h2 h3].include?(cursor.name)
      return true if %w[ul ol].include?(cursor.name) && cursor.css("li").any?
      return true if cursor.name == "p" && cursor.text.to_s.strip.present?

      cursor = cursor.next_element
    end
    false
  end

  # High-value source phrases we actively look for (order = preference).
  KEYWORD_HEADINGS = [
    [ /property\s+features?\s*:/i, "Property Features", "features" ],
    [ /key\s+features?\s*:/i, "Key Features", "features" ],
    [ /parking\s*(?:&|and)\s*amenities\s*:/i, "Parking & Amenities", "parking" ],
    [ /location\s+highlights?\s*:/i, "Location Highlights", "location" ],
    [ /property\s+details?\s*:/i, "Property Details", "highlights" ],
    [ /(?:^|[\n.!?])\s*(?:[\p{Emoji_Presentation}\p{Emoji}\uFE0F]+\s*)*amenities\s*:/iu, "Amenities", "amenities" ],
    [ /(?:^|[\n.!?])\s*(?:[\p{Emoji_Presentation}\p{Emoji}\uFE0F]+\s*)*features\s*:/iu, "Features", "features" ],
    [ /(?:^|[\n.!?])\s*(?:[\p{Emoji_Presentation}\p{Emoji}\uFE0F]+\s*)*highlights\s*:/iu, "Highlights", "highlights" ]
  ].freeze

  # Deterministic scan — used by prompts and tests.
  def self.detect_heading_opportunities(plain)
    text = plain.to_s
    found = []

    KEYWORD_HEADINGS.each do |pattern, heading, kind|
      match = text.match(pattern)
      next unless match
      next if found.any? { |h| h[:heading].casecmp?(heading) }
      # Prefer more specific siblings over bare labels.
      next if heading == "Features" && found.any? { |h| h[:kind] == "features" }
      next if heading == "Amenities" && found.any? { |h| h[:kind].in?(%w[amenities parking]) }
      next if heading == "Highlights" && found.any? { |h| h[:heading].match?(/highlight/i) }

      found << {
        heading: heading,
        source_label: match[0].to_s.strip.sub(/:\s*\z/, ""),
        offset: match.begin(0),
        kind: kind
      }
    end

    # Extra Title-Case colon labels (e.g. “Outdoor Living:”) not in the catalog.
    text.to_enum(:scan, /(?:^|[\n.!?])\s*(?:[\p{Emoji_Presentation}\p{Emoji}\uFE0F]+\s*)*([A-Z][\w'\/-]*(?:\s+(?:&|and|[A-Z][\w'\/-]*)){0,4})\s*:/u).each do
      match = Regexp.last_match
      candidate = match[1].to_s.strip
      next if candidate.blank?
      next if blocked_heading_label?(candidate)
      next unless candidate.match?(HEADING_HINT)

      heading = normalize_heading_label(candidate)
      next if heading.blank?
      next if blocked_heading_label?(heading)
      next if found.any? { |h| h[:heading].casecmp?(heading) }
      kind = classify_heading(heading)
      next if kind == "features" && found.any? { |h| h[:kind] == "features" }
      next if kind == "amenities" && found.any? { |h| h[:kind].in?(%w[amenities parking]) }
      next if kind == "highlights" && found.any? { |h| h[:heading].match?(/highlight/i) }

      found << {
        heading: heading,
        source_label: candidate,
        offset: match.begin(1),
        kind: kind
      }
    end

    # Inline “About the Region” without requiring a trailing colon.
    if text.match?(/about\s+the\s+region/i) && found.none? { |h| h[:kind] == "region" }
      found << {
        heading: "About the Region",
        source_label: "About the Region",
        offset: text.index(/about\s+the\s+region/i) || text.length,
        kind: "region",
        demote: true,
        note: "BOK region chrome — use only if keeping neighborhood context; prefer short Neighborhood blurb or omit"
      }
    end

    found.sort_by { |h| h[:offset].to_i }
  end

  def self.normalize_heading_label(raw)
    label = raw.to_s.gsub(/\s+/, " ").strip
    label = label.sub(/\A[\p{Emoji_Presentation}\p{Emoji}\uFE0F\s]+/, "")
    label = label.sub(/\A(?:property\s+)?features?\z/i, "Property Features")
    label = label.sub(/\Alocation\s+highlights?\z/i, "Location Highlights")
    label = label.sub(/\Aparking\s*(?:&|and)\s*amenities\z/i, "Parking & Amenities")
    label = label.sub(/\Aamenities\z/i, "Amenities")
    label = label.sub(/\Aproperty\s+details?\z/i, "Property Details")
    label = label.sub(/\Ahighlights?\z/i, "Highlights")
    label
  end

  def self.classify_heading(heading)
    case heading
    when /\bparking\b/i then "parking"
    when /\bamenit/i then "amenities"
    when /\bfeature/i then "features"
    when /\blocation|\bnearby|\bcommunity|\bcompound/i then "location"
    when /\bregion|\bneighborhood|\bneighbourhood/i then "region"
    when /\bhighlight|\bdetail|\boverview|\bspec/i then "highlights"
    else "other"
    end
  end

  def self.blocked_heading_label?(label)
    text = label.to_s.strip
    return true if text.match?(HEADING_BLOCKLIST)
    return true if text.match?(/\b(call|whats?\s*app|asking|price|email|phone)\b/i)
    return true if text.match?(/\Acall\s*\/\s*whats?/i)

    false
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
    source_hints = self.class.detect_heading_opportunities(plain)
    opportunities = self.class.bespoke_opportunities

    structure, usage1 = structure_pass!(plain, opportunities, source_hints)
    usage[:structure] = usage1
    structure = enforce_heading_opportunities!(structure, opportunities)
    structure = ground_structure!(structure, plain, opportunities)
    structure = prune_empty_bespoke_sections!(structure)

    html_raw, usage2 = render_pass!(plain, structure, opportunities)
    usage[:render] = usage2

    html = sanitize_html(html_raw)
    html = ensure_headings_present!(html, structure, opportunities)
    grounded = self.class.ground_html(html, plain, opportunities: opportunities)
    html = grounded[:html]
    grounding = {
      "stripped_bullets" => grounded[:stripped_bullets],
      "stripped_headings" => grounded[:stripped_headings]
    }
    raise Error, "empty HTML after grounding" if html.blank?

    if @apply
      @property.update!(description: html)
      Result.new(
        property: @property.reload, input_plain: plain,
        heading_opportunities: opportunities, structure: structure,
        html: html, usage: usage, applied: true, skipped: false, grounding: grounding
      )
    else
      Result.new(
        property: @property, input_plain: plain,
        heading_opportunities: opportunities, structure: structure,
        html: html, usage: usage, applied: false, skipped: false, grounding: grounding
      )
    end
  rescue OpenaiClient::Error, Error, JSON::ParserError => e
    Result.new(
      property: @property, skipped: true, applied: false, error: e.message,
      usage: usage, heading_opportunities: opportunities
    )
  end

  private

  def structure_pass!(plain, opportunities, source_hints)
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
                { "id": "intro"|"features"|"parking"|"location"|"other",
                  "heading": "exact display heading",
                  "from_source_keyword": true/false,
                  "summary": "1-2 sentence outline of what belongs here",
                  "bullet_candidates": ["short factual bullets pulled ONLY from source", "..."] }
              ],
              "tone_notes": "brief note on how to keep voice grounded",
              "unused_source_keywords": ["source label omitted, with reason"]
            }

            Heading rules (critical — site taxonomy):
            - You MUST use ONLY these exact section headings (bespoke, required when content exists):
              1) "Property Features" — beds, baths, sq ft, rooms, finishes, interior layout
              2) "Parking & Amenities" — parking, pool, security, elevator, HOA, compound amenities
              3) "Location Highlights" — neighborhood, nearby shops/schools/access (omit if no location facts)
            - Do NOT invent other titles ("Key Features", "Prime Location", "Property Highlights",
              "About the Region", bare "Features"/"Amenities"). Map source keywords into the three above.
            - Intro prose stays a lead section with id "intro" and NO heading (or blank heading).
            - Source keyword hints in the payload are packaging clues only — never display those labels
              unless they exactly match our three bespoke headings.
            - Use ONLY facts present in the source. Never invent amenities.
            - bullet_candidates must be verbatim or lightly trimmed from the source.
            - Prefer three populated sections when the source supports them; omit empty ones.
          PROMPT
        },
        {
          role: "user",
          content: JSON.generate({
            title: @property.title,
            property_type: @property.property_type,
            city: @property.city,
            description: plain,
            required_headings: opportunities.map { |h| h[:heading] },
            source_section_hints: source_hints
          })
        }
      ]
    )

    parsed = JSON.parse(response[:content])
    [ parsed, response[:usage] ]
  end

  def render_pass!(plain, structure, opportunities)
    response = @client.chat(
      temperature: 0.3,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You convert real-estate listing copy into polished semantic HTML for an Action Text / Trix editor.
            Return JSON only: { "html": "<div>...</div>" }

            Formatting convention (full polish):
            - Wrap everything in a single <div>.
            - Opening intro as one or two <p> paragraphs (no heading on the intro).
            - Each structure section with a heading becomes <h2>Heading</h2> using the EXACT
              heading string from structure. Allowed headings only:
              "Property Features", "Parking & Amenities", "Location Highlights".
            - Do not invent alternate titles ("Prime Location", "Key Features", "Property Highlights").
            - Amenity / feature lists as <ul><li>…</li></ul>; put the lead noun in <strong>.
            - Keep body prose readable; do not turn the whole listing into a list.
            - Allowed tags only: div, p, br, h2, h3, strong, em, ul, ol, li, a.
            - No classes, styles, images, scripts, or tables.
            - Facts ONLY from the source description + provided structure. Never invent.
            - Every <li> must be supportable by a nearby phrase in source_description.
              If unsure, omit the bullet. Do not “improve” with unstated finishes or amenities.

            Make bespoke sections “pop”: exact heading, tight bullets, strong leads — still truthful.
          PROMPT
        },
        {
          role: "user",
          content: JSON.generate({
            title: @property.title,
            source_description: plain,
            structure: structure,
            required_headings: opportunities.map { |h| h[:heading] }
          })
        }
      ]
    )

    parsed = JSON.parse(response[:content])
    html = parsed["html"].to_s
    [ html, response[:usage] ]
  end

  def ground_structure!(structure, plain, opportunities)
    structure = structure.is_a?(Hash) ? structure.deep_dup : { "sections" => [] }
    sections = Array(structure["sections"]).filter_map do |sec|
      heading = sec["heading"].to_s.strip
      next if heading.present? &&
        !self.class.heading_allowed?(heading, plain, opportunities) &&
        !sec["from_source_keyword"] &&
        !sec["bespoke"]

      bullets = Array(sec["bullet_candidates"]).map { |b| b.to_s.strip }.reject(&:blank?)
      bullets.select! { |b| self.class.phrase_grounded?(b, plain) }
      sec["bullet_candidates"] = bullets
      # Keep bespoke shells so render still has the heading slot when content may land in pass 2;
      # drop free-invented empty sections.
      next if bullets.empty? && !sec["from_source_keyword"] && !sec["bespoke"]

      sec
    end
    structure["sections"] = sections
    structure
  end

  def enforce_heading_opportunities!(structure, opportunities)
    structure = structure.is_a?(Hash) ? structure.deep_dup : { "sections" => [] }
    sections = Array(structure["sections"])

    # Remap any freeform / BOK heading into the closest bespoke slot by kind.
    sections.each do |sec|
      heading = sec["heading"].to_s.strip
      next if heading.blank? # intro
      next if self.class.bespoke_heading?(heading)

      kind = sec["id"].to_s.presence || classify_soft(heading)
      spec = self.class::BESPOKE_HEADINGS.find { |s| s[:kinds].include?(kind) || s[:id] == kind }
      spec ||= self.class::BESPOKE_HEADINGS.first
      sec["heading"] = spec[:heading]
      sec["id"] = spec[:id]
      sec["bespoke"] = true
      sec["from_source_keyword"] = true
    end

    # Merge duplicate bespoke headings' bullets into one section each.
    merged = []
    sections.each do |sec|
      heading = sec["heading"].to_s.strip
      if heading.present? && (existing = merged.find { |s| s["heading"].to_s.casecmp?(heading) })
        existing["bullet_candidates"] = (
          Array(existing["bullet_candidates"]) + Array(sec["bullet_candidates"])
        ).map { |b| b.to_s.strip }.reject(&:blank?).uniq
      else
        merged << sec
      end
    end
    sections = merged

    required = opportunities.reject { |h| h[:demote] }
    required.each do |opp|
      heading = opp[:heading]
      next if sections.any? { |s| s["heading"].to_s.casecmp?(heading) }

      kind = opp[:kind]
      sibling = sections.find { |s| s["id"].to_s == kind || classify_soft(s["heading"]) == kind }
      if sibling
        sibling["heading"] = heading
        sibling["bespoke"] = true
        sibling["from_source_keyword"] = true
        sibling["id"] = kind if sibling["id"].to_s.blank?
      else
        sections << {
          "id" => kind,
          "heading" => heading,
          "bespoke" => true,
          "from_source_keyword" => true,
          "summary" => "Content for #{heading}",
          "bullet_candidates" => []
        }
      end
    end

    # Drop non-taxonomy titles (should already be remapped).
    sections.reject! do |s|
      heading = s["heading"].to_s.strip
      heading.present? && !self.class.bespoke_heading?(heading)
    end

    structure["sections"] = sections
    structure
  end

  def prune_empty_bespoke_sections!(structure)
    structure = structure.is_a?(Hash) ? structure.deep_dup : { "sections" => [] }
    structure["sections"] = Array(structure["sections"]).reject do |sec|
      heading = sec["heading"].to_s.strip
      heading.present? &&
        self.class.bespoke_heading?(heading) &&
        Array(sec["bullet_candidates"]).empty?
    end
    structure
  end

  def classify_soft(heading)
    self.class.classify_heading(heading.to_s)
  end

  def ensure_headings_present!(html, structure, opportunities)
    # Only force-insert bespoke headings that already have grounded bullets.
    required = opportunities.reject { |h| h[:demote] }.map { |h| h[:heading] }.select do |heading|
      section = Array(structure["sections"]).find { |s| s["heading"].to_s.casecmp?(heading) }
      Array(section&.dig("bullet_candidates")).any?
    end
    return dedupe_headings(html) if required.empty?

    missing = required.reject do |heading|
      html.to_s.match?(/<h[23][^>]*>\s*#{Regexp.escape(heading)}\s*<\/h[23]>/i) ||
        html.to_s.match?(/<h[23][^>]*>\s*#{Regexp.escape(ERB::Util.html_escape(heading))}\s*<\/h[23]>/i)
    end
    return dedupe_headings(html) if missing.empty?

    repaired = html.to_s.sub(%r{</div>\s*\z}i, "")
    plain = @property.description_plain
    missing.each do |heading|
      section = Array(structure["sections"]).find { |s| s["heading"].to_s.casecmp?(heading) }
      bullets = Array(section&.dig("bullet_candidates")).first(12).select { |b|
        self.class.phrase_grounded?(b, plain)
      }
      next if bullets.empty?

      repaired << "<h2>#{ERB::Util.html_escape(heading)}</h2>"
      repaired << "<ul>"
      bullets.each { |b| repaired << "<li>#{ERB::Util.html_escape(b.to_s)}</li>" }
      repaired << "</ul>"
    end
    repaired << "</div>" unless repaired.match?(%r{</div>\s*\z}i)
    dedupe_headings(sanitize_html(repaired))
  end

  def dedupe_headings(html)
    seen = {}
    fragment = Nokogiri::HTML::DocumentFragment.parse(html.to_s)
    fragment.css("h2, h3").each do |node|
      key = node.text.to_s.strip.downcase
      if seen[key]
        node.remove
      else
        seen[key] = true
      end
    end
    sanitize_html(fragment.to_html)
  rescue StandardError
    html
  end

  def sanitize_html(html)
    ActionController::Base.helpers.sanitize(
      html.to_s,
      tags: ALLOWED_TAGS,
      attributes: %w[href]
    ).to_s.strip
  end
end
