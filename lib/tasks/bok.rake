namespace :bok do
  desc "Import BOK house listings JSON into properties. Usage: bin/rails \"bok:import[path/to.json]\" or FILE=path bin/rails bok:import"
  task :import, [ :file ] => :environment do |_t, args|
    path = args[:file].presence || ENV["FILE"].presence
    puts "Importing from #{path || "latest houses_last_month_*.json"}…"
    result = BokListingsImporter.import!(path)
    puts "Created: #{result.created}"
    puts "Updated: #{result.updated}"
    puts "Skipped: #{result.skipped}"
    if result.errors.any?
      puts "Errors (#{result.errors.size}):"
      result.errors.first(20).each { |msg| puts "  - #{msg}" }
      puts "  …" if result.errors.size > 20
    end
  end
end
