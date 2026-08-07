# frozen_string_literal: true

# Reconcile missing / city-centroid property pins via public geocoders
# (Photon → Nominatim → Overpass → AI forge → Google).
#
# Dry-run:
#   bin/rails runner script/reconcile_property_coords.rb
#
# Apply all candidates:
#   APPLY=1 SOURCE=deep BOK_ONLY=1 bin/rails runner script/reconcile_property_coords.rb
#
# Env:
#   LIMIT=              max candidates (omit or 0 = all)
#   APPLY=1              write latitude/longitude
#   SOURCE=deep|public_deep|public|auto|photon|nominatim|overpass|google
#   INCLUDE_CITY_ONLY=1  also try city-only stubs
#   BOK_ONLY=1           BOK-imported rows only (default)
#   BOK_ID=BOK-123       single listing
#   OUT=tmp/….json       audit path

STDOUT.sync = true
$stdout.sync = true
$stderr.sync = true

apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }
limit = nil if limit && limit <= 0
sources = ENV.fetch("SOURCE", "deep")
include_city_only = ENV["INCLUDE_CITY_ONLY"].to_s.match?(/\A(1|true|yes)\z/i)
bok_only = ENV.fetch("BOK_ONLY", "1").to_s.match?(/\A(1|true|yes)\z/i)

scope = Property.order(:id)
scope = scope.where.not(bok_id: [ nil, "" ]) if bok_only
scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?

reconciler = PropertyCoordReconciler.new
candidates = []
scope.find_each do |property|
  next unless reconciler.candidate?(property, include_city_only: include_city_only)

  candidates << property
  break if limit && candidates.size >= limit
end

puts "Coord reconcile apply=#{apply} limit=#{limit || 'all'} source=#{sources} city_only=#{include_city_only}"
puts "google_configured=#{GoogleAddressClient.new.configured?} candidates=#{candidates.size}"
puts

stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
mode = apply ? "applied" : "dry"
out_path = ENV.fetch(
  "OUT",
  Rails.root.join("tmp", "coords_reconcile_#{mode}_#{stamp}.json").to_s
)

proposals = []
candidates.each_with_index do |property, index|
  print "[#{index + 1}/#{candidates.size}] #{property.bok_id || property.id} … "
  $stdout.flush
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  row = reconciler.call(
    Property.where(id: property.id),
    limit: 1,
    apply: apply,
    sources: sources,
    include_city_only: include_city_only
  ).first
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

  # Candidate set can shrink between collection and process (e.g. bok sync /
  # concurrent apply), so `.first` may be nil — never crash the batch.
  if row.nil?
    row = PropertyCoordReconciler::Proposal.new(
      property_id: property.id,
      bok_id: property.bok_id,
      title: property.title,
      query: nil,
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
      notes: [ "reconciler returned no proposal (no longer a candidate?)" ]
    )
  end
  proposals << row

  after = row.after
  pin = after ? "#{after[:latitude].round(5)},#{after[:longitude].round(5)}" : "-"
  puts "#{row.action} source=#{row.source || '-'} conf=#{row.confidence || '-'} pin=#{pin} (#{elapsed}s)"
  $stdout.flush

  # Checkpoint audit every 10 rows so a long run isn't all-or-nothing.
  if ((index + 1) % 10).zero? || index + 1 == candidates.size
    serializable = proposals.map do |p|
      {
        "property_id" => p.property_id,
        "bok_id" => p.bok_id,
        "title" => p.title,
        "query" => p.query,
        "before" => p.before,
        "after" => p.after,
        "source" => p.source,
        "osm_type" => p.osm_type,
        "confidence" => p.confidence,
        "action" => p.action,
        "notes" => p.notes
      }
    end
    File.write(out_path, JSON.pretty_generate(serializable))
  end
end

counts = proposals.group_by(&:action).transform_values(&:size)
puts
puts "Summary: #{counts.inspect} (#{proposals.size} candidates)"
puts "Wrote #{out_path}"
puts apply ? "Applied lat/lng where action=applied." : "Dry-run only. Re-run with APPLY=1 to write."
