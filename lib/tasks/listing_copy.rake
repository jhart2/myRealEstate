namespace :listing_copy do
  desc "Dry-run ListingCopyCleaner on existing BOK listings. LIMIT=3 BOK_ID=BOK-123 optional"
  task dry_run: :environment do
    unless OpenaiClient.new.configured?
      abort "OPENAI_API_KEY is not set (check .env)"
    end

    scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
    if ENV["BOK_ID"].present?
      scope = scope.where(bok_id: ENV["BOK_ID"])
    end
    limit = Integer(ENV.fetch("LIMIT", "3"))
    properties = scope.limit(limit).to_a
    abort "No matching properties" if properties.empty?

    puts "Dry-running ListingCopyCleaner on #{properties.size} listing(s)…\n"

    properties.each_with_index do |property, index|
      puts "=" * 72
      puts "[#{index + 1}/#{properties.size}] #{property.bok_id} — #{property.title}"
      puts "URL: #{property.source_url}"
      begin
        result = ListingCopyCleaner.call(property)
      rescue OpenaiClient::Error, ListingCopyCleaner::Error => e
        puts "ERROR: #{e.message}"
        next
      end

      cleaned = result.cleaned
      puts
      puts "TITLE"
      puts "  before: #{property.title}"
      puts "  after:  #{cleaned['title']}"
      puts
      puts "ADDRESS"
      puts "  before: #{property.full_address}"
      puts "  after:  #{[ cleaned['address'], cleaned['city'], cleaned['state'] ].compact_blank.join(", ")}"
      puts
      puts "SPECS"
      puts "  before: beds=#{property.beds} baths=#{property.baths} sqft=#{property.sqft} type=#{property.property_type} tag=#{property.tag}"
      puts "  after:  beds=#{cleaned['beds']} baths=#{cleaned['baths']} sqft=#{cleaned['sqft']} type=#{cleaned['property_type']} tag=#{cleaned['tag']}"
      puts
      puts "DESCRIPTION (before, first 220 chars)"
      puts "  #{property.description.to_s.gsub(/\s+/, " ").truncate(220)}"
      puts "DESCRIPTION (after, first 220 chars)"
      puts "  #{cleaned['description'].to_s.gsub(/\s+/, " ").truncate(220)}"
      puts
      puts "VERIFICATION: #{result.status} (confidence=#{result.verification['confidence']})"
      Array(result.verification["mismatches"]).each do |row|
        puts "  - #{row['field']}: model=#{row['model'].inspect} description=#{row['from_description'].inspect} (#{row['note']})"
      end
      Array(result.verification["notes"]).each do |note|
        puts "  note: #{note}"
      end
      if result.usage
        puts "usage: #{result.usage.inspect}"
      end
      puts
    end

    puts "Dry-run complete (no DB writes)."
  end
end
