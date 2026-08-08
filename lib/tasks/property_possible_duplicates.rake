namespace :properties do
  desc "Find strong listing duplicates (title/price/location/features). DRY_RUN=1 (default) or APPLY=1 to flag. Skips admin-dismissed pairs."
  task flag_possible_duplicates: :environment do
    dry_run = ENV["APPLY"].to_s != "1" && ENV["DRY_RUN"].to_s != "0"
    limit = (ENV["LIMIT_PAIRS"] || 40).to_i

    puts dry_run ? "DRY RUN — no writes" : "APPLY — writing possible_duplicate flags"
    result = PropertyDuplicateDetector.call(dry_run: dry_run, limit_pairs: limit)

    puts "scanned=#{result.scanned}"
    puts "strong_pairs=#{result.pair_count}"
    puts "listings_to_flag=#{result.flagged_ids.size}"
    puts "applied=#{result.applied}"
    puts "sample_pairs:"
    result.pairs.each do |pair|
      puts "  ##{pair.left_id} ↔ ##{pair.right_id} [#{pair.signals.join('+')}] score=#{pair.score}"
      puts "    #{pair.left_slug}"
      puts "    #{pair.right_slug}"
    end
  end
end
