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

  desc "Seed demo users/agents then import packaged BOK listings (staging bootstrap)"
  task bootstrap: :environment do
    Rake::Task["db:seed"].invoke
    Rake::Task["bok:import"].invoke
    puts "Bootstrap complete. Properties: #{Property.count}, Agents: #{Agent.count}"
  end
end

