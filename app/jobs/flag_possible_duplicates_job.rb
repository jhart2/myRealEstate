# Scans active listings for strong near-duplicates and flags possible_duplicate.
#
#   FlagPossibleDuplicatesJob.perform_now(dry_run: true)
#   FlagPossibleDuplicatesJob.perform_later(dry_run: false)
class FlagPossibleDuplicatesJob < ApplicationJob
  queue_as :default

  def perform(dry_run: true, limit_pairs: 50)
    result = PropertyDuplicateDetector.call(dry_run: dry_run, limit_pairs: limit_pairs)
    Rails.logger.info(
      "[FlagPossibleDuplicatesJob] dry_run=#{result.dry_run} scanned=#{result.scanned} " \
      "pairs=#{result.pair_count} flagged=#{result.flagged_ids.size} applied=#{result.applied}"
    )
    result
  end
end
