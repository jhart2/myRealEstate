# Scores property addresses with OpenAI, resolves dirty ones via Google, proposes
# (and optionally applies) address/city/state/zip/lat/lng updates.
#
# Dry-run by default. Pass apply: true (or APPLY=1 in the rake task) to write.
class PropertyAddressBackfill
  class Error < StandardError; end

  Proposal = Struct.new(
    :property_id,
    :bok_id,
    :title,
    :score,
    :grade,
    :issues,
    :suggested_query,
    :before,
    :after,
    :google,
    :action,
    :notes,
    keyword_init: true
  )

  KNOWN_CITIES = (
    BokListingsImporter::CITY_COORDS.keys.map(&:titleize) +
    TrinidadRegion::KEYWORDS.values.flatten.map(&:titleize) +
    BokAddressResolver::EXTRA_PLACES.map(&:titleize)
  ).uniq.freeze

  # Google often collapses Maraval/Woodbrook/Cascade → "Port of Spain".
  METRO_LOCALITIES = [
    "port of spain", "san fernando", "chaguanas", "arima", "scarborough",
    "trinidad", "tobago", "trinidad and tobago", "diego martin regional corporation"
  ].freeze

  def self.call(...)
    new.call(...)
  end

  def self.dry_run(...)
    new.dry_run(...)
  end

  def initialize(
    scorer: AddressCleanlinessScorer.new,
    google: GoogleAddressClient.new,
    score_below: Integer(ENV.fetch("SCORE_BELOW", "70"))
  )
    @scorer = scorer
    @google = google
    @score_below = score_below
  end

  def dry_run(scope = default_scope, limit: nil)
    run(scope, limit: limit, apply: false)
  end

  def call(scope = default_scope, limit: nil, apply: false)
    run(scope, limit: limit, apply: apply)
  end

  private

  def default_scope
    Property.where.not(bok_id: [ nil, "" ]).order(:id)
  end

  def run(scope, limit:, apply:)
    raise Error, "OPENAI_API_KEY is not set" unless OpenaiClient.new.configured?
    raise Error, "GOOGLE_MAPS_API_KEY is not set" unless @google.configured?

    records = limit ? scope.limit(limit).to_a : scope.to_a
    proposals = []

    records.each do |property|
      proposals << process(property, apply: apply)
    rescue AddressCleanlinessScorer::Error, GoogleAddressClient::Error => e
      proposals << Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        score: nil,
        grade: nil,
        issues: [ e.message ],
        suggested_query: nil,
        before: snapshot(property),
        after: nil,
        google: nil,
        action: "error",
        notes: [ e.message ]
      )
    end

    proposals
  end

  def process(property, apply:)
    score = @scorer.call(property)
    before = snapshot(property)
    notes = []

    if score.score >= @score_below && !BokAddressResolver.needs_repair?(property)
      return Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        score: score.score,
        grade: score.grade,
        issues: score.issues,
        suggested_query: score.suggested_query,
        before: before,
        after: nil,
        google: nil,
        action: "skip_clean",
        notes: [ "score #{score.score} >= #{@score_below}; no repair needed" ]
      )
    end

    query = score.suggested_query.presence || property.full_address
    query = enrich_query(query, property)
    region = property.state.presence || detect_region(property)

    resolved = @google.resolve(query: query, region_hint: region)
    unless resolved
      return Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        score: score.score,
        grade: score.grade,
        issues: score.issues,
        suggested_query: query,
        before: before,
        after: nil,
        google: nil,
        action: "unresolved",
        notes: [ "Google returned no result for #{query.inspect}" ]
      )
    end

    after = merge_resolution(property, resolved, notes)
    changed = %i[address city state zip latitude longitude].any? { |k| before[k].to_s != after[k].to_s }

    action =
      if !changed
        "unchanged"
      elsif apply
        property.update!(
          address: after[:address],
          city: after[:city],
          state: after[:state],
          zip: after[:zip],
          latitude: after[:latitude],
          longitude: after[:longitude]
        )
        "applied"
      else
        "would_update"
      end

    Proposal.new(
      property_id: property.id,
      bok_id: property.bok_id,
      title: property.title,
      score: score.score,
      grade: score.grade,
      issues: score.issues,
      suggested_query: query,
      before: before,
      after: after.merge(full_address: BokAddressResolver.format_address(after)),
      google: {
        source: resolved.source,
        formatted_address: resolved.formatted_address,
        confidence: resolved.confidence,
        location_type: resolved.location_type,
        place_id: resolved.place_id
      },
      action: action,
      notes: notes + Array(score.notes.presence)
    )
  end

  def snapshot(property)
    {
      address: property.address.to_s,
      city: property.city.to_s,
      state: property.state.to_s,
      zip: property.zip.to_s,
      latitude: property.latitude,
      longitude: property.longitude,
      full_address: property.full_address
    }
  end

  def enrich_query(query, property)
    q = query.to_s.strip
    blob = "#{property.title} #{property.source_url} #{property.state}".downcase
    if blob.include?("barbados") && !q.match?(/barbados/i)
      "#{q}, Barbados"
    elsif !q.match?(/trinidad|tobago|barbados/i)
      "#{q}, Trinidad and Tobago"
    else
      q
    end
  end

  def detect_region(property)
    blob = "#{property.title} #{property.source_url} #{property.state}".downcase
    return "Barbados" if blob.include?("barbados")

    "Trinidad"
  end

  def merge_resolution(property, resolved, notes)
    current_city = property.city.to_s.strip
    google_city = resolved.city.to_s.strip
    current_address = property.address.to_s.strip

    city =
      if keep_local_city?(current_city, google_city)
        notes << "kept local city #{current_city.inspect} (Google locality #{google_city.inspect})"
        current_city
      else
        google_city.presence || current_city
      end

    street = resolved.address.to_s.strip
    google_has_street = usable_google_street?(street, city, resolved)

    address =
      if google_has_street
        notes << "adopted Google street line"
        street
      elsif marketing_or_stub?(current_address) || current_address.casecmp?(city.to_s)
        notes << "cleared marketing/stub street; using city as address line"
        city.presence || current_address
      elsif current_address.present?
        notes << "kept existing street; Google had no stronger line"
        current_address
      else
        city.presence.to_s
      end

    state = resolved.state.presence || property.state.presence || "Trinidad"
    zip = resolved.zip.presence || property.zip.to_s

    {
      address: address,
      city: city,
      state: state,
      zip: zip,
      latitude: resolved.latitude || property.latitude,
      longitude: resolved.longitude || property.longitude
    }
  end

  def usable_google_street?(street, city, resolved)
    return false if street.blank?
    return false if street.casecmp?(city.to_s)
    return false if plus_code?(street)
    return false if resolved.confidence.to_i < 60
    return false unless resolved.location_type.to_s.match?(/ROOFTOP|RANGE_INTERPOLATED|PREMISE|STREET/i)

    true
  end

  def plus_code?(value)
    value.to_s.match?(/\A[A-Z0-9]{2,}\+[A-Z0-9]{2,}\z/i) ||
      value.to_s.match?(/\b[A-Z0-9]{4,}\+[A-Z0-9]{2,}\b/i)
  end

  def marketing_or_stub?(value)
    v = value.to_s.strip
    return true if v.blank? || placeholder?(v)
    return true if v.match?(/\b(?:for\s+sale|of\s+sale|for\s+rent|reduced|beautifully|upgraded|bedroom|townhouse|family\s+\d|charming|stunning)\b/i)
    return true if v.match?(/\b(?:house|home|property)\s+(?:in|for|of)\b/i)
    return true if v.length > 72

    false
  end

  def keep_local_city?(current, google)
    return false if current.blank? || placeholder?(current)
    return false if google.blank?
    return false if current.casecmp?(google)

    return true if known_city?(current) && metro_locality?(google) && !metro_locality?(current)
    return true if known_city?(current) && !known_city?(google)

    false
  end

  def known_city?(name)
    needle = name.to_s.downcase.strip
    KNOWN_CITIES.any? { |c| c.downcase == needle } ||
      BokListingsImporter::CITY_COORDS.key?(needle)
  end

  def metro_locality?(name)
    METRO_LOCALITIES.include?(name.to_s.downcase.strip)
  end

  def placeholder?(value)
    value.to_s.match?(BokAddressResolver::PLACEHOLDER) || value.to_s.match?(/\bN\/A\b/i)
  end
end
