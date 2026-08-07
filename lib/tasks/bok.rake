namespace :bok do
  desc "Import BOK house listings JSON into properties. Usage: bin/rails \"bok:import[path/to.json]\" or FILE=path bin/rails bok:import"
  task :import, [ :file ] => :environment do |_t, args|
    path = args[:file].presence || ENV["FILE"].presence
    puts "Importing from #{path || "db/data/bok_listings.json (or latest sync file)"}…"
    result = BokListingsImporter.import!(path)
    puts "Created: #{result.created}"
    puts "Updated: #{result.updated}"
    puts "Skipped: #{result.skipped}"
    puts "Removed: #{result.removed}" if result.removed.positive?
    if result.errors.any?
      puts "Errors (#{result.errors.size}):"
      result.errors.first(20).each { |msg| puts "  - #{msg}" }
      puts "  …" if result.errors.size > 20
    end
  end

  desc "Scrape up to BOK_SYNC_MAX_DETAILS (default 250) newest unfinished BOK houses, then import (and push changes to staging)"
  task sync: :environment do
    puts "Starting BOK sync (newest first, lookback #{ENV.fetch("BOK_SYNC_DAYS", "7")} days)…"
    summary = BokListingsSyncJob.perform_now
    puts "JSON: #{summary[:json_path]}"
    puts "Created: #{summary[:created]}"
    puts "Updated: #{summary[:updated]}"
    puts "Skipped: #{summary[:skipped]}"
    puts "Removed: #{summary[:removed]}" if summary[:removed].positive?
    puts "Address enriched: #{summary[:address_enriched]}" if summary[:address_enriched].to_i.positive?
    puts "Copy applied: #{summary[:copy_applied]}" if summary[:copy_applied].to_i.positive?
    puts "Staging push: #{summary[:staging_pushed] ? "yes" : "skipped"}"
    if summary[:errors].any?
      puts "Errors (#{summary[:errors].size}):"
      summary[:errors].first(20).each { |msg| puts "  - #{msg}" }
    end
  end

  desc "Push a BOK listings JSON file to staging Postgres. Usage: bin/rails \"bok:push_staging[path/to.json]\" or FILE=path"
  task :push_staging, [ :file ] => :environment do |_t, args|
    path = args[:file].presence || ENV["FILE"].presence
    path ||= Dir.glob(Rails.root.join("scripts/bok_sync_data/houses_last_month_*.json")).max_by { |p| File.mtime(p) }
    abort "No listings JSON to push. Pass a path or set FILE=." unless path

    puts "Pushing #{path} to staging…"
    StagingListingsPusher.push!(path)
    puts "Done."
  end

  desc "Re-fetch full descriptions for every Property with a BOK source_url (updates description only)"
  task refresh_descriptions: :environment do
    urls = Property.where.not(source_url: [ nil, "" ]).order(:id).pluck(:source_url).uniq
    abort "No properties with source_url to refresh." if urls.empty?

    out_dir = Rails.root.join("scripts/bok_sync_data")
    out_dir.mkpath
    urls_file = out_dir.join("refresh_description_urls.txt")
    urls_file.write(urls.join("\n") + "\n")

    delay = ENV.fetch("BOK_SYNC_DELAY", "4")
    cmd = [
      "python3", Rails.root.join("scripts/bok_gentle_listings_sync.py").to_s,
      "--urls-file", urls_file.to_s,
      "--refetch",
      "--days", ENV.fetch("BOK_SYNC_DAYS", "3650"),
      "--delay", delay,
      "--out-dir", out_dir.to_s
    ]
    puts "Refreshing descriptions for #{urls.size} listings…"
    puts cmd.join(" ")
    ok = system(*cmd)
    abort "Scraper failed (#{$?.exitstatus})" unless ok

    newest = Dir.glob(out_dir.join("houses_last_month_*.json")).max_by { |p| File.mtime(p) }
    abort "No sync JSON written" unless newest

    rows = JSON.parse(File.read(newest))
    updated = 0
    missing = 0
    unchanged = 0
    rows.each do |row|
      desc = row["description"].to_s.strip
      next if desc.blank?

      property = if row["bok_id"].present?
        Property.find_by(bok_id: row["bok_id"]) || Property.find_by(source_url: row["url"])
      else
        Property.find_by(source_url: row["url"])
      end
      unless property
        missing += 1
        next
      end

      if property.description.to_s == desc
        unchanged += 1
      else
        property.update!(description: desc)
        updated += 1
      end
    end

    puts "JSON: #{newest}"
    puts "Updated descriptions: #{updated}"
    puts "Unchanged: #{unchanged}"
    puts "Rows without matching property: #{missing}"
    long = Property.where.not(bok_id: nil).where("LENGTH(description) > 1200").count
    puts "BOK descriptions longer than 1200 chars: #{long}"
  end

  desc "Dry-run (default) or apply BOK address/city N/A repairs. APPLY=1 to write."
  task fix_locations: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    proposals = BokAddressResolver.dry_run
    puts "#{proposals.size} properties would change"
    proposals.each do |row|
      puts
      puts "#{row[:bok_id]}  #{row[:title]}"
      puts "  before: #{row[:before][:full_address]}"
      puts "  after:  #{row[:after][:full_address]}"
      puts "  notes:  #{Array(row[:notes]).join("; ")}"
    end

    if apply
      updated = 0
      proposals.each do |row|
        property = Property.find(row[:id])
        property.update!(
          address: row[:after][:address],
          city: row[:after][:city],
          state: row[:after][:state],
          zip: row[:after][:zip],
          latitude: row[:after][:latitude],
          longitude: row[:after][:longitude]
        )
        updated += 1
      end
      puts
      puts "Applied #{updated} updates."
    else
      puts
      puts "Dry-run only. Re-run with APPLY=1 to write changes."
    end
  end

  desc "Seed demo users/agents then import packaged BOK listings (staging bootstrap)"
  task bootstrap: :environment do
    Rake::Task["db:seed"].invoke
    Rake::Task["bok:import"].invoke
    puts "Bootstrap complete. Properties: #{Property.count}, Agents: #{Agent.count}"
  end
end
