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

  desc "Scrape up to BOK_SYNC_MAX_DETAILS (default 250) newest unfinished BOK houses, then import"
  task sync: :environment do
    puts "Starting BOK sync (newest first, lookback #{ENV.fetch("BOK_SYNC_DAYS", "7")} days)…"
    summary = BokListingsSyncJob.perform_now
    puts "JSON: #{summary[:json_path]}"
    puts "Created: #{summary[:created]}"
    puts "Updated: #{summary[:updated]}"
    puts "Skipped: #{summary[:skipped]}"
    puts "Removed: #{summary[:removed]}" if summary[:removed].positive?
    if summary[:errors].any?
      puts "Errors (#{summary[:errors].size}):"
      summary[:errors].first(20).each { |msg| puts "  - #{msg}" }
    end
  end

  desc "Re-fetch full descriptions for every Property with a BOK source_url, then re-import"
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

    result = BokListingsImporter.import!(newest)
    puts "JSON: #{newest}"
    puts "Created: #{result.created}"
    puts "Updated: #{result.updated}"
    puts "Skipped: #{result.skipped}"
    puts "Removed: #{result.removed}" if result.removed.positive?
    long = Property.where.not(bok_id: nil).where("LENGTH(description) > 1200").count
    puts "BOK descriptions longer than 1200 chars: #{long}"
  end

  desc "Seed demo users/agents then import packaged BOK listings (staging bootstrap)"
  task bootstrap: :environment do
    Rake::Task["db:seed"].invoke
    Rake::Task["bok:import"].invoke
    puts "Bootstrap complete. Properties: #{Property.count}, Agents: #{Agent.count}"
  end
end

