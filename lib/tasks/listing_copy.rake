namespace :listing_copy do
  desc "Dry-run ListingCopyCleaner on existing BOK listings. LIMIT=3 BOK_ID=BOK-123 optional"
  task dry_run: :environment do
    unless OpenaiClient.new.configured?
      abort "OPENAI_API_KEY is not set (check .env)"
    end

    scope = Property.where.not(bok_id: [ nil, "" ])
    if ENV["BOK_ID"].present?
      scope = scope.where(bok_id: ENV["BOK_ID"])
    elsif ENV["RANDOM"].to_s != "0"
      scope = scope.order(Arel.sql("RANDOM()"))
    else
      scope = scope.order(:id)
    end
    limit = Integer(ENV.fetch("LIMIT", "3"))
    properties = scope.limit(limit).to_a
    abort "No matching properties" if properties.empty?

    puts "Dry-running ListingCopyCleaner on #{properties.size} listing(s) (random=#{ENV['RANDOM'].to_s != '0'})…\n"

    results = []
    out_path = ENV.fetch(
      "OUT",
      Rails.root.join("tmp", "listing_copy_dry_run_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.json").to_s
    )

    properties.each_with_index do |property, index|
      puts "=" * 72
      puts "[#{index + 1}/#{properties.size}] #{property.bok_id} — #{property.title}"
      puts "URL: #{property.source_url}"
      begin
        result = ListingCopyCleaner.call(property)
      rescue OpenaiClient::Error, ListingCopyCleaner::Error => e
        puts "ERROR: #{e.message}"
        results << { "bok_id" => property.bok_id, "error" => e.message }
        next
      end

      cleaned = result.cleaned
      after_address = [ cleaned["address"], cleaned["city"], cleaned["state"] ].compact_blank.join(", ")
      row = {
        "bok_id" => property.bok_id,
        "source_url" => property.source_url,
        "before" => {
          "title" => property.title,
          "address" => property.full_address,
          "description" => property.description.to_s,
          "beds" => property.beds,
          "baths" => property.baths,
          "sqft" => property.sqft,
          "lot_sqft" => property.try(:lot_sqft),
          "acres" => property.try(:acres),
          "property_type" => property.property_type,
          "tag" => property.tag
        },
        "after" => {
          "title" => cleaned["title"],
          "address" => after_address,
          "address_parts" => {
            "address" => cleaned["address"],
            "city" => cleaned["city"],
            "state" => cleaned["state"]
          },
          "description" => cleaned["description"].to_s,
          "beds" => cleaned["beds"],
          "baths" => cleaned["baths"],
          "sqft" => cleaned["sqft"],
          "lot_sqft" => cleaned["lot_sqft"],
          "acres" => cleaned["acres"],
          "property_type" => cleaned["property_type"],
          "tag" => cleaned["tag"],
          "features" => cleaned["features"]
        },
        "verification" => result.verification,
        "usage" => result.usage
      }
      results << row

      puts
      puts "TITLE"
      puts "  before: #{property.title}"
      puts "  after:  #{cleaned['title']}"
      puts
      puts "ADDRESS"
      puts "  before: #{property.full_address}"
      puts "  after:  #{after_address}"
      puts
      puts "SPECS"
      puts "  before: beds=#{property.beds} baths=#{property.baths} sqft=#{property.sqft} lot=#{property.try(:lot_sqft)} acres=#{property.try(:acres)} type=#{property.property_type} tag=#{property.tag}"
      puts "  after:  beds=#{cleaned['beds']} baths=#{cleaned['baths']} sqft=#{cleaned['sqft']} lot=#{cleaned['lot_sqft']} acres=#{cleaned['acres']} type=#{cleaned['property_type']} tag=#{cleaned['tag']}"
      puts
      puts "DESCRIPTION (before)"
      puts property.description.to_s
      puts
      puts "DESCRIPTION (after)"
      puts cleaned["description"].to_s
      puts
      puts "VERIFICATION: #{result.status} (confidence=#{result.verification['confidence']})"
      Array(result.verification["mismatches"]).each do |mismatch|
        puts "  - #{mismatch['field']}: model=#{mismatch['model'].inspect} description=#{mismatch['from_description'].inspect} (#{mismatch['note']})"
      end
      Array(result.verification["notes"]).each do |note|
        puts "  note: #{note}"
      end
      if result.usage
        puts "usage: #{result.usage.inspect}"
      end
      puts
    end

    FileUtils.mkdir_p(File.dirname(out_path))
    File.write(out_path, JSON.pretty_generate({
      "generated_at" => Time.now.utc.iso8601,
      "count" => results.size,
      "listings" => results
    }))
    puts "Dry-run complete (no DB writes). Wrote #{out_path}"
  end

  desc "Apply ListingCopyCleaner via OpenAI. Clean → apply or flag only. APPLY=1 to write. LIMIT=3 BOK_ID= optional"
  task apply: :environment do
    $stdout.sync = true
    unless OpenaiClient.new.configured?
      abort "OPENAI_API_KEY is not set (check .env)"
    end
    apply = ENV["APPLY"].to_s == "1"

    scope = Property.where.not(bok_id: [ nil, "" ])
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    scope = scope.order(:id)
    limit = Integer(ENV.fetch("LIMIT", "3"))
    properties = if limit <= 0
      scope.to_a
    else
      scope.limit(limit).to_a
    end
    abort "No matching properties" if properties.empty?

    puts "#{apply ? 'Applying' : 'Previewing'} OpenAI clean→apply-or-flag on #{properties.size} listing(s)…"
    puts "(Safe rematches are a separate dry daisy: bin/rails listing_copy:daisy)\n"

    applied = skipped = errors = 0
    properties.each_with_index do |property, index|
      puts "[#{index + 1}/#{properties.size}] #{property.bok_id} — #{property.title}"
      unless apply
        result = ListingCopyCleaner.call(property)
        if result.skip?
          skipped += 1
          puts "  would skip+flag: #{result.mismatch_scenario}"
        else
          applied += 1
          puts "  would apply (status=#{result.status})"
        end
        next
      end

      outcome = ListingCopyApplier.call(property)
      if outcome.error
        errors += 1
        puts "  ERROR/flagged: #{outcome.error}"
      elsif outcome.skipped?
        skipped += 1
        puts "  skipped+flagged: #{property.reload.copy_review_notes['scenario']}"
      else
        applied += 1
        puts "  applied"
      end
    end

    puts "Done. applied=#{applied} skipped_flagged=#{skipped} errors=#{errors} write=#{apply}"
  end

  desc "Dry daisy chain of safe rematches (no OpenAI): size → half-bath → combo → type → sparse"
  task daisy: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    before = scope.count
    puts "Dry daisy on #{before} flagged listing(s)…"
    puts "  order: #{ListingCopyApplier::SAFE_POLICY_ORDER.join(' → ')}"

    stats = ListingCopyApplier.daisy_chain_safe_flags!(scope)
    Array(stats[:steps]).each do |policy, step|
      puts "  #{policy}: applied=#{step[:applied]} skipped=#{step[:skipped]}"
    end
    puts "Done. applied=#{stats[:applied]} remaining_in_scope=#{stats[:remaining]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: safe size rematches only (no OpenAI)"
  task apply_safe_sizes: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry size rematch on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_size_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: evidenced half-bath rematches only (no OpenAI)"
  task apply_safe_half_baths: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry half-bath rematch on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_half_bath_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: size + evidenced half-bath combo only (no OpenAI)"
  task apply_safe_combos: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry size+half-bath combo on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_combo_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: size rematch + nil→N beds/baths with literal evidence (no OpenAI)"
  task apply_safe_nil_fill_specs: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry size+nil-fill specs on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_nil_fill_specs_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: title-strong property type rematches only (no OpenAI)"
  task apply_safe_types: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry title-strong type rematch on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_type_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end

  desc "Dry link: sparse SEO title+description (keep features; no OpenAI)"
  task apply_safe_sparse: :environment do
    $stdout.sync = true
    scope = Property.copy_needs_review
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    puts "Dry sparse title+description on #{scope.count} flagged listing(s)…"
    stats = ListingCopyApplier.reprocess_safe_sparse_flags!(scope)
    puts "Done. applied=#{stats[:applied]} skipped=#{stats[:skipped]}"
    puts "Queue remaining: #{Property.copy_needs_review.count}"
  end
end
