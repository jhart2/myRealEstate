# Hourly BOK sync: scrape up to N newest unfinished house listings in a lookback
# window, then upsert into Property via BokListingsImporter.
#
#   BokListingsSyncJob.perform_now
#   bin/rails bok:sync
#
# Env (optional):
#   BOK_SYNC_DAYS         lookback days (default 7)
#   BOK_SYNC_MAX_DETAILS  detail fetches per run (default 250)
#   BOK_SYNC_DELAY        polite delay seconds (default 4)
#   BOK_SYNC_SKIP_SEARCH  "1" to sitemap-only (default on for hourly)
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

    seed_known_urls_into_cache!
    reopen_style_skips_in_cache!
    json_path = run_scraper!(days:, max_details:, delay:, skip_search_crawl: skip_search)
    result = BokListingsImporter.import!(json_path)

    Rails.logger.info(
      "[BokListingsSyncJob] imported created=#{result.created} updated=#{result.updated} " \
      "skipped=#{result.skipped} removed=#{result.removed} errors=#{result.errors.size} " \
      "from=#{json_path}"
    )

    {
      json_path: json_path.to_s,
      created: result.created,
      updated: result.updated,
      skipped: result.skipped,
      removed: result.removed,
      errors: result.errors
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
    Rails.logger.info("[BokListingsSyncJob] seeded #{added} known source_urls into progress cache")
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
    Rails.logger.info("[BokListingsSyncJob] reopened #{removed.size} previously style-skipped URLs")
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

    Rails.logger.info("[BokListingsSyncJob] running: #{cmd.join(" ")}")
    ok = execute_scraper!(cmd)
    unless ok
      status = $?.respond_to?(:exitstatus) ? $?.exitstatus : "unknown"
      raise SyncError, "BOK scraper exited #{status}"
    end

    newest = Dir.glob(out_dir.join("houses_last_month_*.json")).max_by { |p| File.mtime(p) }
    raise SyncError, "No houses_last_month_*.json written under #{out_dir}" unless newest

    if before && File.mtime(newest) <= before
      Rails.logger.warn("[BokListingsSyncJob] no newer JSON stamp; importing latest #{newest}")
    end

    Pathname.new(newest)
  end

  # Isolated for tests; wraps Kernel#system.
  def execute_scraper!(cmd)
    system(*cmd)
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
