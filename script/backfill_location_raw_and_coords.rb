# frozen_string_literal: true

# Backfill location_raw from BOK feed JSON + Location-led coord reconcile.
#
#   bin/rails runner script/backfill_location_raw_and_coords.rb
#   APPLY=1 SOURCE=public INCLUDE_CITY_ONLY=1 bin/rails runner script/backfill_location_raw_and_coords.rb
#
# Env:
#   APPLY=1                 write location_raw + coords
#   SOURCE=public|deep|…    coord sources (default public for speed)
#   LIMIT=N                 max coord candidates
#   POS_ONLY=1              only Port-of-Spain default pins (default 1)
#   INCLUDE_CITY_ONLY=1     also community centroids (default 1)
#   OUT=tmp/….json

require "json"

STDOUT.sync = true

apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
pos_only = ENV.fetch("POS_ONLY", "1").to_s.match?(/\A(1|true|yes)\z/i)
include_city_only = ENV.fetch("INCLUDE_CITY_ONLY", "1").to_s.match?(/\A(1|true|yes)\z/i)
sources = ENV.fetch("SOURCE", "public")
limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }
limit = nil if limit && limit <= 0

def load_feed_locations
  files = Dir.glob(Rails.root.join("scripts/bok_sync_data/houses_last_month_*.json"))
    .sort_by { |f| File.mtime(f) }
    .reverse
  by_bok = {}
  by_url = {}
  files.each do |f|
    rows = JSON.parse(File.read(f))
    next unless rows.is_a?(Array)

    rows.each do |r|
      bok = r["bok_id"].to_s.strip.presence
      url = r["url"].to_s.strip.presence
      loc = BokLocationToolkit.sanitize(r["location"])
      next if loc.blank?

      by_bok[bok] ||= loc if bok
      by_url[url] ||= loc if url
    end
  end
  [ by_bok, by_url ]
end

by_bok, by_url = load_feed_locations
filled = 0
Property.find_each do |p|
  next if p.location_raw.present?

  loc = (p.bok_id.present? && by_bok[p.bok_id]) || (p.source_url.present? && by_url[p.source_url])
  next if loc.blank?

  if apply
    p.update_columns(location_raw: loc, updated_at: Time.current)
  end
  filled += 1
end
puts "location_raw backfill candidates=#{filled} apply=#{apply}"

scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
if pos_only
  dlat, dlng = BokListingsImporter::DEFAULT_COORDS
  scope = scope.where("ABS(latitude - ?) < 0.00025 AND ABS(longitude - ?) < 0.00025", dlat, dlng)
end

reconciler = PropertyCoordReconciler.new
ids = []
scope.find_each do |p|
  next unless reconciler.candidate?(p, include_city_only: include_city_only)

  ids << p.id
  break if limit && ids.size >= limit
end

puts "coord candidates=#{ids.size} source=#{sources} pos_only=#{pos_only} apply=#{apply}"

proposals = []
ids.each_with_index do |id, index|
  property = Property.find(id)
  print "[#{index + 1}/#{ids.size}] #{property.bok_id || id} … "
  $stdout.flush
  row = reconciler.call(
    Property.where(id: id),
    limit: 1,
    apply: apply,
    sources: sources,
    include_city_only: include_city_only
  ).first
  proposals << row
  after = row&.after
  puts "#{row&.action} #{after && after[:latitude] ? "#{after[:latitude]},#{after[:longitude]}" : ""} #{row&.notes&.last}"
end

counts = proposals.compact.group_by(&:action).transform_values(&:size)
stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
out = ENV.fetch("OUT", Rails.root.join("tmp", "location_raw_coords_#{apply ? 'apply' : 'dry'}_#{stamp}.json").to_s)
File.write(
  out,
  JSON.pretty_generate(
    summary: {
      location_raw_filled: filled,
      candidates: ids.size,
      counts: counts,
      apply: apply,
      sources: sources
    },
    proposals: proposals.compact.map { |p|
      p.to_h.merge(notes: p.notes)
    }
  )
)
puts "counts=#{counts.inspect}"
puts "wrote #{out}"
