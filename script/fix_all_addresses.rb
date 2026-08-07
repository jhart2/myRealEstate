# frozen_string_literal: true

# Fix all local BOK addresses using batched OpenAI (+ Google when needed).
# Quality-gated: never demote a stronger existing street line.
#
#   APPLY=1 bin/rails runner script/fix_all_addresses.rb
#   DRY only: bin/rails runner script/fix_all_addresses.rb
#   ADDRESS_BRAIN_BATCH=15 LIMIT=50  optional

STDOUT.sync = true
$stdout.sync = true

apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
batch_size = Integer(ENV.fetch("ADDRESS_BRAIN_BATCH", "12"))
limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }

ENV["BOK_ADDRESS_BRAIN"] = "1" # force AI brain on for this script

scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
scope = scope.limit(limit) if limit
properties = scope.to_a
total = properties.size

puts "Batched AI address fix apply=#{apply} batch=#{batch_size} total=#{total}"
puts "openai=#{OpenaiClient.new.configured?} google=#{GoogleAddressClient.new.configured?}"
puts

brain = ListingAddressBrain.new
items = properties.map do |property|
  row = {
    "title" => property.title,
    "location" => property.city,
    "url" => property.source_url,
    "description" => property.description.to_s,
    "bok_id" => property.bok_id,
    "address" => property.address
  }
  heuristic = BokAddressResolver.call(row)
  { id: property.bok_id, row: row, heuristic: heuristic, property: property }
end

weak_count = items.count { |i| ListingAddressBrain.weak_document?(i[:row], i[:heuristic]) }
puts "Weak docs needing AI: #{weak_count} / #{total}"
puts "Running enrich_batch…"

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results = brain.enrich_batch(items.map { |i| i.slice(:id, :row, :heuristic) }, batch_size: batch_size)
elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
puts "Batch enrich done in #{elapsed}s (#{results.size} results)"
puts

changed = []
skipped_worse = 0
unchanged = 0
errors = []

items.each_with_index do |item, index|
  property = item[:property]
  place = results[item[:id]] || results[item[:id].to_s]
  unless place
    errors << { bok_id: item[:id], error: "missing result" }
    next
  end

  before = {
    address: property.address.to_s,
    city: property.city.to_s,
    state: property.state.to_s,
    zip: property.zip.to_s,
    latitude: property.latitude,
    longitude: property.longitude
  }
  after = {
    address: place.address.to_s,
    city: place.city.to_s,
    state: place.state.to_s,
    zip: place.zip.to_s,
    latitude: place.latitude || property.latitude,
    longitude: place.longitude || property.longitude
  }

  bq = BokAddressResolver.address_quality(before[:address], before[:city])
  aq = BokAddressResolver.address_quality(after[:address], after[:city])

  island_blob = "#{property.title} #{property.source_url} #{property.city}".downcase
  if after[:state] == "Tobago" && before[:state] != "Tobago" &&
     !(island_blob.match?(/\btobago\b/) && !island_blob.match?(/trinidad\s+and\s+tobago/))
    after[:state] = before[:state]
  end

  if aq < bq || (bq >= 3 && aq <= bq && before[:address].match?(/\d/) && !after[:address].match?(/\d/))
    skipped_worse += 1
    next
  end

  if aq == bq && !BokAddressResolver.marketing_text?(before[:address])
    unless after[:address].casecmp?(before[:address]) || after[:address].length >= before[:address].length
      skipped_worse += 1
      next
    end
  end

  fields = %i[address city state zip latitude longitude].select { |k| before[k].to_s != after[k].to_s }
  if fields.empty?
    unchanged += 1
    next
  end

  entry = {
    id: property.id,
    bok_id: property.bok_id,
    title: property.title,
    source: place.source,
    quality: { before: bq, after: aq },
    fields: fields,
    before: before.merge(full_address: property.full_address),
    after: after.merge(full_address: BokAddressResolver.format_address(after)),
    notes: place.notes
  }
  changed << entry

  if apply
    property.update!(
      address: after[:address],
      city: after[:city],
      state: after[:state],
      zip: after[:zip],
      latitude: after[:latitude],
      longitude: after[:longitude]
    )
  end

  if ((index + 1) % 50).zero? || index + 1 == total
    puts "… reviewed #{index + 1}/#{total} changed=#{changed.size} skipped_worse=#{skipped_worse}"
  end
rescue StandardError => e
  errors << { bok_id: item[:id], error: e.message }
  warn "ERROR #{item[:id]}: #{e.message}"
end

stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
out = Rails.root.join("tmp", "address_fix_all_#{apply ? 'applied' : 'dry'}_#{stamp}.json")
File.write(out, JSON.pretty_generate({
  apply: apply,
  changed_count: changed.size,
  unchanged: unchanged,
  skipped_worse: skipped_worse,
  weak_count: weak_count,
  batch_size: batch_size,
  enrich_seconds: elapsed,
  errors: errors,
  by_source: changed.group_by { |c| c[:source] }.transform_values(&:size),
  changes: changed
}))

puts
puts "Changed=#{changed.size} Unchanged=#{unchanged} SkippedWorse=#{skipped_worse} Errors=#{errors.size}"
puts "By source: #{changed.group_by { |c| c[:source] }.transform_values(&:size)}"
puts
changed.first(25).each do |c|
  puts "#{c[:bok_id]} q#{c[:quality][:before]}→#{c[:quality][:after]} [#{c[:source]}]"
  puts "  before: #{c[:before][:full_address]}"
  puts "  after:  #{c[:after][:full_address]}"
end
puts "…" if changed.size > 25
puts
puts "Wrote #{out}"
puts(apply ? "Applied to local DB." : "Dry-run only. Re-run with APPLY=1 to write.")
