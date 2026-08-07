# Hourly BOK sync: scrape up to N newest unfinished listings in an expanding
# lookback window, then upsert into Property via BokListingsImporter.
#
#   BokListingsSyncJob.perform_now
#   bin/rails bok:sync
#
# Env (optional):
#   BOK_SYNC_DAYS          starting lookback peg + expansion step in days (default 7).
#                          progress_cache.lookback_days grows by this when a window
#                          is fully fetched so later runs reach further back.
#   BOK_SYNC_MAX_DETAILS   detail fetches per run (default 250)
#   BOK_SYNC_DELAY         polite delay seconds (default 4)
#   BOK_SYNC_SKIP_SEARCH   "1" to sitemap-only (default on for hourly)
#   BOK_SYNC_PUSH_STAGING  "0" to skip staging DB push (default: push outside test)
#   BOK_APPLY_LISTING_COPY "0" to skip OpenAI listing-copy on create/update
#                          (never rewrites after status=ok or polished rich HTML;
#                           safe rematches: bin/rails listing_copy:daisy)
#   BOK_ADDRESS_BRAIN      "1" to OpenAI(+Google) enrich weak addresses on create only
#                          (existing rows keep stored address; never re-reconciled)
#   ADDRESS_BRAIN_BATCH    batch size for bulk backfill script (default 12)
#   BOK_COORD_RECONCILE    "0" to skip post-create street pin reconcile (default: on)
#   BOK_COORD_RECONCILE_SOURCES  deep|public_deep|public|auto (default: deep)
#   BOK_COORD_RECONCILE_LIMIT    optional cap per sync run (creates only)
#   BOK_OFFER_RECONCILE    "0" to skip post-import sale/rent+price reconcile (default: on)
#   BOK_SYNC_QUIET         "1" to silence stdout progress (tests default quiet)
#   BOK_SYNC_PROGRESS_EVERY import progress cadence in rows (default 25)
#
class BokListingsSyncJob < ApplicationJob
  queue_as :default

  DEFAULT_DAYS = 7
  DEFAULT_MAX_DETAILS = 250
  DEFAULT_DELAY = 4.0

  class SyncError < StandardError; end

  def perform(days: nil, max_details: nil, delay: nil, skip_search_crawl: nil)
    days = integer_opt(days, "BOK_SYNC_DAYS", DEFAULT_DAYS)
    max_details = integer_opt(max_details, "BOK_SYNC_MAX_DETAILS", DEFAULT_MAX_DETAILS)
    delay = float_opt(delay, "BOK_SYNC_DELAY", DEFAULT_DELAY)
    skip_search = boolean_opt(skip_search_crawl, "BOK_SYNC_SKIP_SEARCH", true)

    BokSyncProgress.say(
      "phase=start days_peg=#{days} max_details=#{max_details} delay=#{delay}s " \
      "(scraper expands lookback_days in progress_cache when window clears)"
    )
    seed_known_urls_into_cache!
    reopen_style_skips_in_cache!

    BokSyncProgress.say("phase=scrape")
    json_path = run_scraper!(days:, max_details:, delay:, skip_search_crawl: skip_search)

    BokSyncProgress.say("phase=import file=#{File.basename(json_path.to_s)}")
    result = BokListingsImporter.import!(json_path)

    BokSyncProgress.say(
      "phase=import_done created=#{result.created} updated=#{result.updated} " \
      "skipped=#{result.skipped} removed=#{result.removed} deduped=#{result.deduped} " \
      "errors=#{result.errors.size} copy_applied=#{result.copy_applied} " \
      "copy_flagged=#{result.copy_flagged} address_enriched=#{result.address_enriched}"
    )

    BokSyncProgress.say("phase=offer_reconcile")
    offers = reconcile_offers_if_needed!(json_path)
    if offers.is_a?(Hash) && Array(offers[:touched_bok_ids]).any?
      result.touched_bok_ids |= Array(offers[:touched_bok_ids])
    end

    BokSyncProgress.say("phase=coord_reconcile")
    coords = reconcile_coords_if_needed!(result)

    BokSyncProgress.say("phase=staging_push")
    staging = push_to_staging_if_needed!(json_path, result, offer_updates: offers.is_a?(Hash) ? offers[:updated].to_i : 0)

    BokSyncProgress.say(
      "phase=done staging=#{staging ? "yes" : "no"} " \
      "offers=#{offers.is_a?(Hash) ? offers[:updated].to_i : 0} " \
      "coords_applied=#{coords.is_a?(Hash) ? coords[:applied].to_i : 0}"
    )

    {
      json_path: json_path.to_s,
      created: result.created,
      updated: result.updated,
      skipped: result.skipped,
      removed: result.removed,
      deduped: result.deduped,
      copy_applied: result.copy_applied,
      copy_flagged: result.copy_flagged,
      address_enriched: result.address_enriched,
      offers_reconciled: offers,
      coords_reconciled: coords,
      errors: result.errors,
      staging_pushed: staging
    }
  end

  private

  def out_dir
    Rails.root.join("scripts/bok_sync_data")
  end

  def cache_path
    out_dir.join("progress_cache.json")
  end

  def script_path
    Rails.root.join("scripts/bok_gentle_listings_sync.py")
  end

  # Mark URLs already in the DB as completed so hourly runs keep walking
  # newer→older until they hit listings we do not have yet.
  def seed_known_urls_into_cache!
    known = Property.where.not(source_url: [ nil, "" ]).pluck(:source_url)
    return if known.empty?

    cache = if cache_path.exist?
      JSON.parse(cache_path.read)
    else
      { "completed" => {}, "listings" => [] }
    end
    completed = cache["completed"] ||= {}
    added = 0
    known.each do |url|
      next if completed.key?(url)

      completed[url] = { "ok" => true, "kept" => true, "reason" => "already_in_db" }
      added += 1
    end
    return if added.zero?

    cache["updated_at"] = Time.current.utc.iso8601
    out_dir.mkpath
    cache_path.write(JSON.pretty_generate(cache))
    BokSyncProgress.say("seeded #{added} known source_urls into progress cache")
  end

  # Older runs skipped non-House styles. Clear those cache rows so the next
  # sync re-fetches them now that all styles are imported.
  def reopen_style_skips_in_cache!
    return unless cache_path.exist?

    cache = JSON.parse(cache_path.read)
    completed = cache["completed"]
    return unless completed.is_a?(Hash)

    reopen_reasons = /\Astyle=|not_house\z/
    removed = completed.keys.select do |url|
      meta = completed[url]
      meta.is_a?(Hash) && meta["kept"] == false && meta["reason"].to_s.match?(reopen_reasons)
    end
    return if removed.empty?

    removed.each { |url| completed.delete(url) }
    cache["updated_at"] = Time.current.utc.iso8601
    cache_path.write(JSON.pretty_generate(cache))
    BokSyncProgress.say("reopened #{removed.size} previously style-skipped URLs")
  end

  def run_scraper!(days:, max_details:, delay:, skip_search_crawl:)
    raise SyncError, "Missing scraper at #{script_path}" unless script_path.exist?

    cmd = [
      "python3", script_path.to_s,
      "--days", days.to_s,
      "--delay", delay.to_s,
      "--max-details", max_details.to_s,
      "--out-dir", out_dir.to_s
    ]
    cmd << "--skip-search-crawl" if skip_search_crawl

    before = Dir.glob(out_dir.join("houses_last_month_*.json")).map { |p| File.mtime(p) }.max

    BokSyncProgress.say("scraper #{cmd.join(" ")}")
    ok = execute_scraper!(cmd)
    unless ok
      status = $?.respond_to?(:exitstatus) ? $?.exitstatus : "unknown"
      raise SyncError, "BOK scraper exited #{status}"
    end

    newest = Dir.glob(out_dir.join("houses_last_month_*.json")).max_by { |p| File.mtime(p) }
    raise SyncError, "No houses_last_month_*.json written under #{out_dir}" unless newest

    if before && File.mtime(newest) <= before
      BokSyncProgress.say("warn: no newer JSON stamp; importing latest #{File.basename(newest)}")
    end

    Pathname.new(newest)
  end

  # Isolated for tests; wraps Kernel#system.
  def execute_scraper!(cmd)
    system(*cmd)
  end

  # Mirror created/updated/removed rows onto staging Postgres after local import.
  def push_to_staging_if_needed!(json_path, result, offer_updates: 0)
    return false unless StagingListingsPusher.enabled?

    changed = result.created.to_i + result.updated.to_i + result.removed.to_i
    if changed.zero? && offer_updates.to_i.zero?
      BokSyncProgress.say("staging push skipped (no local changes)")
      return false
    end

    BokSyncProgress.say("staging push starting (local_changes=#{changed} offer_updates=#{offer_updates.to_i})")
    StagingListingsPusher.push!(json_path)
    BokSyncProgress.say("staging push complete")
    true
  rescue StagingListingsPusher::PushError => e
    raise SyncError, e.message
  end

  # After import: re-apply dual sale/rent price+tag rules across the feed so
  # skipped/unchanged rows still pick up resolve_offer fixes.
  def reconcile_offers_if_needed!(json_path)
    enabled = boolean_opt(nil, "BOK_OFFER_RECONCILE", true)
    unless enabled
      BokSyncProgress.say("offer reconcile skipped (BOK_OFFER_RECONCILE=0)")
      return { enabled: false }
    end

    summary = BokListingsImporter.reconcile_offers!(json_path)
    BokSyncProgress.say(
      "offer reconcile done updated=#{summary[:updated]} skipped=#{summary[:skipped]} " \
      "missing=#{summary[:missing]} errors=#{summary[:errors].size}"
    )
    summary.merge(enabled: true)
  rescue StandardError => e
    BokSyncProgress.say("offer reconcile failed: #{e.class}: #{e.message}")
    Rails.logger.error("[BokListingsSyncJob] offer reconcile failed: #{e.class}: #{e.message}")
    { enabled: true, error: "#{e.class}: #{e.message}" }
  end

  # After import: pin-reconcile newly created listings once only.
  # Never re-reconcile updates / residual city-centroid backfill on hourly sync.
  def reconcile_coords_if_needed!(result = nil)
    enabled = boolean_opt(nil, "BOK_COORD_RECONCILE", true)
    unless enabled
      BokSyncProgress.say("coord reconcile skipped (BOK_COORD_RECONCILE=0)")
      return { enabled: false }
    end

    created = Array(result&.created_bok_ids).compact.uniq
    if created.empty?
      BokSyncProgress.say("coord reconcile skipped (no creates — never re-reconcile)")
      return { enabled: true, candidates: 0, skipped: "no_creates" }
    end

    sources = ENV.fetch("BOK_COORD_RECONCILE_SOURCES", "deep")
    limit = ENV["BOK_COORD_RECONCILE_LIMIT"].presence&.then { |v| Integer(v) }
    include_city_only = boolean_opt(nil, "BOK_COORD_RECONCILE_CITY_ONLY", true)
    scope = Property.where(bok_id: created).order(:id)
    BokSyncProgress.say("coord reconcile scope=created_bok_ids count=#{created.size} sources=#{sources}")

    proposals = PropertyCoordReconciler.new.call(
      scope,
      limit: limit,
      apply: true,
      sources: sources,
      include_city_only: include_city_only
    )

    counts = proposals.group_by(&:action).transform_values(&:size)
    BokSyncProgress.say(
      "coord reconcile done city_only=#{include_city_only} candidates=#{proposals.size} #{counts.inspect}"
    )

    {
      enabled: true,
      sources: sources,
      include_city_only: include_city_only,
      candidates: proposals.size,
      applied: counts["applied"].to_i,
      proposed: counts["proposed"].to_i,
      unresolved: counts["unresolved"].to_i,
      noop: counts["noop"].to_i,
      rejected_city_level: counts["rejected_city_level"].to_i,
      errors: counts["error"].to_i
    }
  rescue StandardError => e
    BokSyncProgress.say("coord reconcile failed: #{e.class}: #{e.message}")
    Rails.logger.error("[BokListingsSyncJob] coord reconcile failed: #{e.class}: #{e.message}")
    { enabled: true, error: "#{e.class}: #{e.message}" }
  end

  def integer_opt(value, env_key, default)
    raw = value.nil? ? ENV[env_key] : value
    raw.nil? ? default : Integer(raw)
  end

  def float_opt(value, env_key, default)
    raw = value.nil? ? ENV[env_key] : value
    raw.nil? ? default : Float(raw)
  end

  def boolean_opt(value, env_key, default)
    return value unless value.nil?

    raw = ENV[env_key]
    return default if raw.nil?

    !%w[0 false off no].include?(raw.to_s.strip.downcase)
  end
end
