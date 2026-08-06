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

  desc "Seed demo users/agents then import packaged BOK listings (staging bootstrap)"
  task bootstrap: :environment do
    Rake::Task["db:seed"].invoke
    Rake::Task["bok:import"].invoke
    puts "Bootstrap complete. Properties: #{Property.count}, Agents: #{Agent.count}"
  end
end
