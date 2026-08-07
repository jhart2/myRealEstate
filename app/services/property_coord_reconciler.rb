# frozen_string_literal: true

# Reconcile missing or city-centroid Property pins using public geocoders
# (Komoot Photon / OSM Nominatim), Overpass street-in-bbox, AI query forge,
# and optional Google fallback.
#
#   PropertyCoordReconciler.new.call(Property.limit(8), apply: false, sources: :deep)
class PropertyCoordReconciler
  class Error < StandardError; end

  MIN_MOVE_DEG = 0.0008 # ~90m — ignore tiny jitter vs existing pin
  # Reject street hits farther than ~12km from the known city centroid.
  MAX_CITY_DISTANCE_DEG = 0.11
  PHOTON_STREET_TYPES = %w[street house].freeze
  NOMINATIM_STREETISH = %w[
    house building residential living_street tertiary secondary primary
    unclassified service road
  ].freeze

  Proposal = Struct.new(
    :property_id,
    :bok_id,
    :title,
    :query,
    :before,
    :after,
    :source,
    :osm_type,
    :confidence,
    :action,
    :notes,
    keyword_init: true
  )

  def initialize(
    photon: PhotonGeocoder.new,
    nominatim: NominatimGeocoder.new,
    google: GoogleAddressClient.new,
    overpass: OverpassStreetFinder.new,
    forge: AddressQueryForge.new,
    street_geocoder: nil
  )
    @photon = photon
    @nominatim = nominatim
    @google = google
    @overpass = overpass
    @forge = forge
    @street_geocoder = street_geocoder || PropertyStreetGeocoder.new(google: google)
  end

  # sources:
  #   :public      photon → nominatim
  #   :deep        photon → nominatim → overpass → AI forge (+photon/nominatim) → google
  #   :public_deep deep without google
  #   :auto        photon → nominatim → google
  def call(scope, limit: nil, apply: false, sources: :deep, include_city_only: false)
    sources = normalize_sources(sources)
    candidates = collect_candidates(scope, limit: limit, include_city_only: include_city_only)

    # Single-property callers (script / jobs) expect a Proposal, not [].
    # Candidate status can change between collection and process time.
    if candidates.empty? && limit == 1
      property = scope.limit(1).first
      return [ skipped_proposal(property) ] if property
    end

    total = candidates.size
    BokSyncProgress.say("coord reconcile #{total} candidate(s) apply=#{apply} sources=#{Array(sources).join(",")}")
    candidates.each_with_index.map do |property, index|
      proposal = reconcile_one(property, apply: apply, sources: sources, include_city_only: include_city_only)
      done = index + 1
      if done == total || (done % 5).zero? || total <= 10
        BokSyncProgress.say(
          "coord #{done}/#{total} #{property.bok_id || property.id} → #{proposal.action}" \
          "#{proposal.source ? " (#{proposal.source})" : ""}"
        )
      end
      proposal
    end
  end

  def candidate?(property, include_city_only: false)
    lat = property.latitude
    lng = property.longitude
    missing = lat.blank? || lng.blank?
    city_level = @street_geocoder.city_level_coords?(lat, lng)
    streetish = @street_geocoder.street_worthy?(property.address, property.city)
    on_default = BokLocationToolkit.default_coords?(lat, lng)

    return true if missing
    return true if on_default # always try to escape POS dump pins
    return true if streetish && city_level
    return true if include_city_only && city_level
    return true if city_level && BokLocationToolkit.sanitize(property.try(:location_raw)).present?

    false
  end

  private

  def skipped_proposal(property)
    Proposal.new(
      property_id: property.id,
      bok_id: property.bok_id,
      title: property.title,
      query: build_query(property),
      before: {
        address: property.address.to_s,
        city: property.city.to_s,
        state: property.state.to_s,
        latitude: property.latitude&.to_f,
        longitude: property.longitude&.to_f
      },
      after: nil,
      source: nil,
      osm_type: nil,
      confidence: nil,
      action: "error",
      notes: [ "skipped: not a coord reconcile candidate at process time" ]
    )
  end

  def normalize_sources(sources)
    case sources.to_s.downcase
    when "deep", "" then %i[photon nominatim overpass forge google]
    when "public_deep" then %i[photon nominatim overpass forge]
    when "auto" then %i[photon nominatim google]
    when "public" then %i[photon nominatim]
    when "photon" then %i[photon]
    when "nominatim" then %i[nominatim]
    when "overpass" then %i[overpass]
    when "google" then %i[google]
    else
      Array(sources).map(&:to_sym)
    end
  end

  def collect_candidates(scope, limit:, include_city_only:)
    out = []
    scope.find_each do |property|
      next unless candidate?(property, include_city_only: include_city_only)

      out << property
      break if limit && out.size >= limit
    end
    out
  end

  def reconcile_one(property, apply:, sources:, include_city_only:)
    query = build_query(property)
    before = {
      address: property.address.to_s,
      city: property.city.to_s,
      state: property.state.to_s,
      latitude: property.latitude&.to_f,
      longitude: property.longitude&.to_f
    }
    notes = []
    hit = nil

    sources.each do |source|
      hit = resolve_via(source, property, query, include_city_only: include_city_only, notes: notes)
      break if hit
    end

    unless hit
      return Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        query: query,
        before: before,
        after: nil,
        source: nil,
        osm_type: nil,
        confidence: nil,
        action: "unresolved",
        notes: notes.presence || [ "no usable public/google hit" ]
      )
    end

    after = {
      address: property.address.to_s,
      city: property.city.to_s,
      state: property.state.to_s,
      latitude: hit[:latitude].to_f,
      longitude: hit[:longitude].to_f
    }

    if same_pin?(before, after)
      return Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        query: query,
        before: before,
        after: after,
        source: hit[:source],
        osm_type: hit[:osm_type],
        confidence: hit[:confidence],
        action: "noop",
        notes: notes + [ "hit matches existing pin" ]
      )
    end

    # Never "upgrade" a street listing to another city-centroid dump —
    # except when escaping the Port-of-Spain default dump via Location-led locality.
    if @street_geocoder.street_worthy?(property.address, property.city) &&
       @street_geocoder.city_level_coords?(after[:latitude], after[:longitude]) &&
       before[:latitude].present? &&
       !community_escape_from_default?(before, after)
      return Proposal.new(
        property_id: property.id,
        bok_id: property.bok_id,
        title: property.title,
        query: query,
        before: before,
        after: after,
        source: hit[:source],
        osm_type: hit[:osm_type],
        confidence: hit[:confidence],
        action: "rejected_city_level",
        notes: notes + [ "resolved pin is still a city centroid" ]
      )
    end

    action = "proposed"
    if apply
      property.update!(latitude: after[:latitude], longitude: after[:longitude])
      action = "applied"
    end

    Proposal.new(
      property_id: property.id,
      bok_id: property.bok_id,
      title: property.title,
      query: query,
      before: before,
      after: after,
      source: hit[:source],
      osm_type: hit[:osm_type],
      confidence: hit[:confidence],
      action: action,
      notes: notes
    )
  rescue StandardError => e
    Proposal.new(
      property_id: property.id,
      bok_id: property.bok_id,
      title: property.title,
      query: query,
      before: before,
      after: nil,
      source: nil,
      osm_type: nil,
      confidence: nil,
      action: "error",
      notes: [ "#{e.class}: #{e.message}" ]
    )
  end

  def resolve_via(source, property, query, include_city_only:, notes:)
    street_required = street_required?(property, include_city_only)
    case source
    when :photon
      resolve_with_variants(property, :photon, street_required: street_required, notes: notes)
    when :nominatim
      resolve_with_variants(property, :nominatim, street_required: street_required, notes: notes)
    when :overpass
      resolve_overpass(property, notes: notes)
    when :forge
      resolve_forge(property, street_required: street_required, notes: notes)
    when :google
      resolve_google(property, query, notes: notes)
    end
  end

  def resolve_overpass(property, notes:)
    hit = @overpass.find(
      name: property.address,
      city: property.city,
      state: property.state
    )
    unless hit
      notes << "overpass=nil"
      return nil
    end
    unless near_city?(hit.latitude, hit.longitude, property.city, hit_label: hit.name)
      notes << "overpass_far_from_city=#{hit.name}"
      return nil
    end

    notes << "overpass=#{hit.name}"
    {
      latitude: hit.latitude,
      longitude: hit.longitude,
      source: "overpass",
      osm_type: [ "highway", hit.highway ].compact.join(":"),
      confidence: 80
    }
  rescue OverpassStreetFinder::Error => e
    notes << "overpass_error=#{e.message}"
    nil
  end

  def resolve_forge(property, street_required:, notes:)
    forged = @forge.call(
      address: property.address,
      city: property.city,
      state: property.state,
      title: property.title,
      description: property.try(:description_plain).presence || property.try(:description).to_s
    )
    notes << "forge_source=#{forged[:source]}"
    notes << "forge_notes=#{forged[:notes]}" if forged[:notes].present?

    Array(forged[:queries]).each do |variant|
      hit = resolve_photon(
        variant,
        street_required: street_required,
        notes: notes,
        address: property.address,
        city: property.city,
        prefer_places: true,
        location_raw: property.try(:location_raw)
      )
      return hit.merge(source: "forge+photon") if hit

      hit = resolve_nominatim(
        variant,
        street_required: street_required,
        notes: notes,
        address: property.address,
        city: property.city,
        location_raw: property.try(:location_raw)
      )
      return hit.merge(source: "forge+nominatim") if hit
    end

    # Last forge attempt: Overpass using forged street token from first query.
    if forged[:queries].first.present?
      street_guess = forged[:queries].first.to_s.split(",").first.to_s.strip
      begin
        hit = @overpass.find(name: street_guess, city: property.city, state: property.state)
        if hit && near_city?(hit.latitude, hit.longitude, property.city, hit_label: hit.name)
          notes << "forge+overpass=#{hit.name}"
          return {
            latitude: hit.latitude,
            longitude: hit.longitude,
            source: "forge+overpass",
            osm_type: [ "highway", hit.highway ].compact.join(":"),
            confidence: 75
          }
        end
      rescue OverpassStreetFinder::Error => e
        notes << "forge_overpass_error=#{e.message}"
      end
    end

    nil
  end

  def resolve_with_variants(property, source, street_required:, notes:)
    variants = query_variants(property)
    variants.each_with_index do |variant, index|
      # Location-led queries (front of the list) must not require estate/street name match.
      location_led = location_led_variant?(property, variant)
      require_street = street_required && !location_led
      hit =
        case source
        when :photon
          resolve_photon(
            variant,
            street_required: require_street,
            notes: notes,
            address: property.address,
            city: property.city,
            prefer_places: location_led || BokLocationToolkit.default_coords?(property.latitude, property.longitude),
            location_raw: property.try(:location_raw)
          )
        when :nominatim
          resolve_nominatim(
            variant,
            street_required: require_street,
            notes: notes,
            address: property.address,
            city: property.city,
            location_raw: property.try(:location_raw)
          )
        end
      return hit if hit
    end
    nil
  end

  def query_variants(property)
    location = BokLocationToolkit.sanitize(property.try(:location_raw))
    location_queries = BokLocationToolkit.geo_queries(
      location_raw: location.presence || property.city,
      address: nil,
      city: property.city,
      state: property.state
    )

    address = property.address.to_s.strip
    city = property.city.to_s.strip
    state = property.state.to_s.strip
    country = country_for(state)

    address_queries = [
      [ address, city, country ].reject(&:blank?).uniq.join(", "),
      [ address, city, state, country ].reject(&:blank?).uniq.join(", "),
      [ address, city ].reject(&:blank?).uniq.join(", ")
    ]
    address_queries << [ address, country ].reject(&:blank?).uniq.join(", ") if city.blank?
    address_queries.reject!(&:blank?)

    (location_queries + address_queries).uniq
  end

  def location_led_variant?(property, variant)
    location = BokLocationToolkit.sanitize(property.try(:location_raw)).presence || property.city.to_s
    tags = BokLocationToolkit.tags(location)
    return false if tags.empty?

    hay = variant.to_s.downcase
    tags.any? { |t| hay.include?(t.to_s.downcase) } ||
      hay.include?("chin chin road")
  end

  def community_escape_from_default?(before, after)
    return false unless BokLocationToolkit.default_coords?(before[:latitude], before[:longitude])
    return false if BokLocationToolkit.default_coords?(after[:latitude], after[:longitude])

    true
  end

  def country_for(state)
    case state.to_s.downcase
    when "barbados" then "Barbados"
    when "tobago" then "Tobago, Trinidad and Tobago"
    else "Trinidad and Tobago"
    end
  end

  def street_required?(property, include_city_only)
    return false if property.latitude.blank? || property.longitude.blank?
    return false if include_city_only && !@street_geocoder.street_worthy?(property.address, property.city)

    @street_geocoder.street_worthy?(property.address, property.city)
  end

  def resolve_photon(query, street_required:, notes:, address:, city:, prefer_places: false, location_raw: nil)
    hits = @photon.search(query, limit: 8)
    notes << "photon(#{query.truncate(48)})=#{hits.size}"
    pick = pick_photon(
      hits,
      street_required: street_required,
      address: address,
      city: city,
      prefer_places: prefer_places,
      location_raw: location_raw
    )
    return nil unless pick

    {
      latitude: pick[:lat],
      longitude: pick[:lng],
      source: "photon",
      osm_type: pick[:type].to_s,
      confidence: photon_confidence(pick[:type], name_match: street_name_match?(pick[:name], address, city: city))
    }
  rescue PhotonGeocoder::Error => e
    notes << "photon_error=#{e.message}"
    nil
  end

  def pick_photon(hits, street_required:, address:, city:, prefer_places: false, location_raw: nil)
    ranked = hits.select do |h|
      photon_in_region?(h) &&
        near_city?(h[:lat], h[:lng], city, hit_city: h[:city], hit_label: h[:label], location_raw: location_raw)
    end
    ranked = ranked.select { |h| BokLocationToolkit.place_like_photon?(h) } if prefer_places

    if street_required
      pool = ranked.select do |h|
        PHOTON_STREET_TYPES.include?(h[:type].to_s) && street_name_match?(h[:name], address, city: city)
      end
    else
      pool = ranked.select { |h| BokLocationToolkit.place_like_photon?(h) }
      pool = ranked if pool.empty?
    end
    return nil if pool.empty?

    city_only = city_only_address?(address, city)
    pool.min_by do |h|
      [
        if city_only
          place_bias_rank(h[:type])
        else
          street_name_match?(h[:name], address, city: city) ? 0 : 1
        end,
        distance_to_known_city(h[:lat], h[:lng], city, location_raw),
        photon_rank(h[:type])
      ]
    end
  end

  # When we know CITY_COORDS for the listing city (or Location tags), geography wins.
  # Label-only "Mayaro" matches must not green-light a Sangre Grande taxi POI.
  def near_city?(lat, lng, city, hit_city: nil, hit_label: nil, location_raw: nil)
    city_name = city.to_s.strip
    return true if city_name.blank?

    known = known_locality_centroids(city_name, location_raw)
    if known.any?
      return known.any? { |coords| within_city_radius?(lat, lng, coords) }
    end

    # Unknown community: require the hit to mention the city / Location tag.
    return true if city_token_match?(hit_city, city_name) || city_token_match?(hit_label, city_name)

    Array(BokLocationToolkit.tags(location_raw)).any? do |tag|
      tag.present? && (city_token_match?(hit_city, tag) || city_token_match?(hit_label, tag))
    end
  end

  def known_locality_centroids(city_name, location_raw)
    names = [ city_name ] + Array(BokLocationToolkit.tags(location_raw))
    names.map { |n| city_centroid(n) }.compact.uniq
  end

  def within_city_radius?(lat, lng, coords)
    (lat.to_f - coords[0]).abs <= MAX_CITY_DISTANCE_DEG &&
      (lng.to_f - coords[1]).abs <= MAX_CITY_DISTANCE_DEG
  end

  def distance_to_known_city(lat, lng, city, location_raw)
    known = known_locality_centroids(city, location_raw)
    return 0.0 if known.empty?

    known.map { |c| Math.hypot(lat.to_f - c[0], lng.to_f - c[1]) }.min
  end

  # Bare city / community address: don't treat city token as a street name match.
  def city_only_address?(address, city)
    return true if address.to_s.strip.blank?
    return true unless @street_geocoder.street_worthy?(address, city)

    a = normalize_street_token(address)
    c = normalize_street_token(city)
    a.present? && c.present? && (a == c || c.include?(a) || a.include?(c))
  end

  def place_bias_rank(type)
    case type.to_s
    when "city", "town", "village", "hamlet", "locality", "district", "suburb", "neighbourhood", "neighborhood"
      0
    when "street" then 1
    when "house" then 3
    else 2
    end
  end

  def city_centroid(city)
    key = city.to_s.downcase.strip
    return BokListingsImporter::CITY_COORDS[key] if BokListingsImporter::CITY_COORDS.key?(key)

    BokListingsImporter::CITY_COORDS.find { |name, _| key.include?(name) || name.include?(key) }&.last
  end

  def city_token_match?(haystack, city)
    needle = city.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squeeze(" ").strip
    hay = haystack.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squeeze(" ").strip
    return false if needle.blank? || hay.blank?
    return true if hay == needle || hay.include?(needle)

    # Allow "South Oropouche" ≈ "Oropouche"
    ntoks = needle.split.reject { |t| %w[north south east west central].include?(t) }
    return false if ntoks.empty?

    ntoks.all? { |t| t.length > 2 && hay.split.include?(t) }
  end

  def street_name_match?(hit_name, address, city: nil)
    return false if city_only_address?(address, city)

    needle = normalize_street_token(address)
    hay = normalize_street_token(hit_name)
    return false if needle.blank? || hay.blank?
    return true if hay == needle
    return true if hay.start_with?("#{needle} ") || hay.end_with?(" #{needle}") || hay.include?(" #{needle} ")

    ntoks = needle.split
    htoks = hay.split
    return true if ntoks.size > 1 && (ntoks - htoks).empty?

    false
  end

  def normalize_street_token(value)
    value.to_s.downcase
      .sub(/\A#?\d+[a-z]?\s+/, "")
      .gsub(/\b(street|st|road|rd|avenue|ave|drive|dr|lane|ln|trace|boulevard|blvd|crescent|close|court|ct)\b/, " ")
      .gsub(/[^a-z0-9\s]/, " ")
      .squeeze(" ")
      .strip
  end

  def photon_rank(type)
    case type.to_s
    when "house" then 0
    when "street" then 1
    when "district", "locality", "neighbourhood" then 2
    when "city", "town", "village" then 3
    else 4
    end
  end

  def photon_confidence(type, name_match: false)
    base =
      case type.to_s
      when "house" then 90
      when "street" then 75
      when "district", "locality", "neighbourhood" then 55
      else 40
      end
    name_match ? base : [ base - 15, 40 ].max
  end

  def photon_in_region?(hit)
    lat = hit[:lat].to_f
    lng = hit[:lng].to_f
    return true if hit[:in_tt]
    return true if lat.between?(NominatimGeocoder::TT_SOUTH, NominatimGeocoder::TT_NORTH) &&
                   lng.between?(NominatimGeocoder::TT_WEST, NominatimGeocoder::TT_EAST)
    return true if lat.between?(NominatimGeocoder::BB_SOUTH, NominatimGeocoder::BB_NORTH) &&
                   lng.between?(NominatimGeocoder::BB_WEST, NominatimGeocoder::BB_EAST)

    false
  end

  def resolve_nominatim(query, street_required:, notes:, address:, city:, location_raw: nil)
    hits = @nominatim.search(query, limit: 5)
    notes << "nominatim(#{query.truncate(48)})=#{hits.size}"
    pool = hits.select do |h|
      near_city?(
        h.latitude, h.longitude, city,
        hit_city: h.city, hit_label: h.display_name, location_raw: location_raw
      )
    end
    pool = street_required ? pool.select { |h| streetish_nominatim?(h) } : pool
    if street_required
      pool = pool.select { |h| street_name_match?(h.address.presence || h.display_name, address) }
    end
    pick = @nominatim.pick_best(pool)
    return nil unless pick

    {
      latitude: pick.latitude,
      longitude: pick.longitude,
      source: "nominatim",
      osm_type: [ pick.osm_class, pick.osm_value ].compact.join(":"),
      confidence: nominatim_confidence(pick, name_match: street_name_match?(pick.address.presence || pick.display_name, address))
    }
  rescue NominatimGeocoder::Error => e
    notes << "nominatim_error=#{e.message}"
    nil
  end

  def streetish_nominatim?(hit)
    value = hit.osm_value.to_s
    klass = hit.osm_class.to_s
    return true if NOMINATIM_STREETISH.include?(value)
    return true if klass == "building"
    return true if klass == "highway"
    return true if hit.address.present? && !%w[city town village country].include?(value)

    false
  end

  def nominatim_confidence(hit, name_match: false)
    base =
      case
      when hit.osm_value.to_s == "house" || hit.osm_class.to_s == "building" then 90
      when streetish_nominatim?(hit) then 75
      else 50
      end
    name_match ? base : [ base - 15, 40 ].max
  end

  def resolve_google(property, query, notes:)
    unless @google.configured?
      notes << "google_skipped=unconfigured"
      return nil
    end

    # Prefer existing street refine gates when address is street-worthy.
    if @street_geocoder.needs_refine?(property)
      refined = @street_geocoder.refine(property)
      if refined && near_city?(refined.latitude, refined.longitude, property.city)
        return {
          latitude: refined.latitude,
          longitude: refined.longitude,
          source: refined.source.to_s.presence || "google",
          osm_type: refined.location_type.to_s,
          confidence: refined.confidence
        }
      end
      notes << "google_street_refine=nil"
    end

    resolved = @google.resolve(query: query, region_hint: property.state.presence || "Trinidad")
    unless resolved&.latitude && resolved&.longitude
      notes << "google_resolve=nil"
      return nil
    end
    if resolved.confidence.to_i < PropertyStreetGeocoder::MIN_CONFIDENCE
      notes << "google_low_conf=#{resolved.confidence}"
      return nil
    end
    unless near_city?(resolved.latitude, resolved.longitude, property.city, hit_label: resolved.formatted_address)
      notes << "google_far_from_city"
      return nil
    end

    {
      latitude: resolved.latitude,
      longitude: resolved.longitude,
      source: resolved.source.to_s.presence || "google",
      osm_type: resolved.location_type.to_s,
      confidence: resolved.confidence
    }
  rescue GoogleAddressClient::Error => e
    notes << "google_error=#{e.message}"
    nil
  end

  def build_query(property)
    query_variants(property).first
  end

  def same_pin?(before, after)
    return false if before[:latitude].blank? || before[:longitude].blank?

    (before[:latitude] - after[:latitude]).abs < MIN_MOVE_DEG &&
      (before[:longitude] - after[:longitude]).abs < MIN_MOVE_DEG
  end
end
