namespace :addresses do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Rank property addresses with OpenAI cleanliness scores and resolve dirty ones via Google Geocoding.
    Dry-run by default. APPLY=1 to write. LIMIT=10 SCORE_BELOW=70 BOK_ID=BOK-123 OUT=tmp/out.json
  DESC
  task rank_and_backfill: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    score_below = Integer(ENV.fetch("SCORE_BELOW", "70"))
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }

    scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    if ENV["RANDOM"].to_s == "1"
      scope = scope.reorder(Arel.sql("RANDOM()"))
    end

    puts "Address rank + Google resolve (apply=#{apply}, score_below=#{score_below}, limit=#{limit || 'all'})…"
    puts

    service = PropertyAddressBackfill.new(score_below: score_below)
    proposals = service.call(scope, limit: limit, apply: apply)

    out_path = ENV.fetch(
      "OUT",
      Rails.root.join("tmp", "address_backfill_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.json").to_s
    )

    serializable = proposals.map do |p|
      {
        "property_id" => p.property_id,
        "bok_id" => p.bok_id,
        "title" => p.title,
        "score" => p.score,
        "grade" => p.grade,
        "issues" => p.issues,
        "suggested_query" => p.suggested_query,
        "before" => p.before,
        "after" => p.after,
        "google" => p.google,
        "action" => p.action,
        "notes" => p.notes
      }
    end
    File.write(out_path, JSON.pretty_generate(serializable))

    counts = proposals.group_by(&:action).transform_values(&:size)
    proposals.each do |row|
      puts "=" * 72
      puts "#{row.bok_id}  score=#{row.score} grade=#{row.grade} action=#{row.action}"
      puts "  title: #{row.title}"
      puts "  before: #{row.before&.dig(:full_address) || row.before}"
      puts "  after:  #{row.after&.dig(:full_address)}" if row.after
      puts "  google: #{row.google&.dig(:formatted_address)} (#{row.google&.dig(:source)}, conf=#{row.google&.dig(:confidence)})" if row.google
      puts "  issues: #{Array(row.issues).join('; ')}" if row.issues.present?
      puts "  notes:  #{Array(row.notes).join('; ')}" if row.notes.present?
    end

    puts
    puts "Summary: #{counts.inspect}"
    puts "Wrote #{out_path}"
    puts apply ? "Applied updates where action=applied." : "Dry-run only. Re-run with APPLY=1 to write."
  end

  desc <<~DESC.gsub(/\s+/, " ").strip
    Re-geocode street-like addresses that are still parked on CITY_COORDS / DEFAULT
    centroids. Lat/lng only — does not invent streets for city-only stubs.
    Dry-run by default. APPLY=1 to write. LIMIT=50 BOK_ONLY=1
  DESC
  task geocode_streets: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }
    google = GoogleAddressClient.new
    abort "GOOGLE_MAPS_API_KEY is not set" unless google.configured?

    scope = Property.where.not(latitude: nil, longitude: nil).order(:id)
    scope = scope.where.not(bok_id: [ nil, "" ]) if ENV["BOK_ONLY"].to_s.match?(/\A(1|true|yes)\z/i)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?

    geocoder = PropertyStreetGeocoder.new(google: google)
    candidates = []
    scope.find_each do |property|
      next unless geocoder.needs_refine?(property)

      candidates << property
      break if limit && candidates.size >= limit
    end

    puts "Street geocode backfill (apply=#{apply}, candidates=#{candidates.size})"
    updated = 0
    skipped = 0
    failed = 0

    candidates.each do |property|
      before = [ property.latitude.to_f, property.longitude.to_f ]
      refined = geocoder.refine(property)
      unless refined
        skipped += 1
        puts "  skip ##{property.id} #{property.address}, #{property.city} (no usable geocode)"
        next
      end

      after = [ refined.latitude.to_f, refined.longitude.to_f ]
      puts "  ##{property.id} #{property.address}, #{property.city}"
      puts "    #{before.map { |n| n.round(5) }.join(',')} → #{after.map { |n| n.round(5) }.join(',')} (conf=#{refined.confidence})"

      if apply
        property.update!(latitude: refined.latitude, longitude: refined.longitude)
        updated += 1
      end
    rescue GoogleAddressClient::Error => e
      failed += 1
      puts "  error ##{property.id}: #{e.message}"
    end

    puts
    puts "Summary: candidates=#{candidates.size} updated=#{updated} skipped=#{skipped} failed=#{failed}"
    puts apply ? "Applied lat/lng updates." : "Dry-run only. Re-run with APPLY=1 to write."
  end

  desc <<~DESC.gsub(/\s+/, " ").strip
    Reconcile missing / city-centroid pins via Photon, Nominatim, Overpass street-in-bbox,
    AI query forge, optional Google. Dry-run default.
    APPLY=1 LIMIT=20 SOURCE=deep|public_deep|public|auto BOK_ID= BOK_ONLY=1
  DESC
  task reconcile_coords: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }
    sources = ENV.fetch("SOURCE", "deep")
    scope = Property.order(:id)
    scope = scope.where.not(bok_id: [ nil, "" ]) if ENV.fetch("BOK_ONLY", "1").to_s.match?(/\A(1|true|yes)\z/i)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?

    proposals = PropertyCoordReconciler.new.call(scope, limit: limit, apply: apply, sources: sources)
    counts = proposals.group_by(&:action).transform_values(&:size)
    proposals.each do |row|
      puts "#{row.bok_id || row.property_id}  #{row.action}  #{row.source}  conf=#{row.confidence}"
      next unless row.after && row.before

      puts "  #{row.before[:latitude]},#{row.before[:longitude]} → #{row.after[:latitude]},#{row.after[:longitude]}"
    end
    puts "Summary: #{counts.inspect}"
    puts apply ? "Applied." : "Dry-run only. Re-run with APPLY=1 to write."
  end

  desc "Score only (no Google calls). LIMIT=10 BOK_ID= optional"
  task rank: :environment do
    unless OpenaiClient.new.configured?
      abort "OPENAI_API_KEY is not set (check .env)"
    end

    limit = Integer(ENV.fetch("LIMIT", "10"))
    scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    scope = scope.reorder(Arel.sql("RANDOM()")) if ENV["RANDOM"].to_s == "1"

    scorer = AddressCleanlinessScorer.new
    scope.limit(limit).each do |property|
      score = scorer.call(property)
      puts "#{property.bok_id}  #{score.score}/#{score.grade}  #{property.full_address}"
      puts "  issues: #{score.issues.join('; ')}" if score.issues.any?
      puts "  query:  #{score.suggested_query}"
      puts
    end
  end
end
