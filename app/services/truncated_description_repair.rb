# One-shot: find truncated descriptions → refetch full BOK body → listing-copy
# clean → rich HTML polish → inplace update.
#
#   TruncatedDescriptionRepair.call(apply: false)           # dry-run
#   TruncatedDescriptionRepair.call(apply: true, limit: 5)
#   TruncatedDescriptionRepair.call(bok_id: "BOK-1032113", apply: true)
#   TruncatedDescriptionRepair.call(refetch: false)         # list candidates only
#
require "json"

class TruncatedDescriptionRepair
  class Error < StandardError; end

  Result = Struct.new(
    :candidates, :refetched, :updated, :enhanced, :skipped, :errors, :rows, :json_path,
    keyword_init: true
  )

  def self.call(**kwargs)
    new(**kwargs).call
  end

  def initialize(
    apply: false,
    enhance: true,
    refetch: true,
    limit: nil,
    bok_id: nil,
    scope: nil,
    delay: ENV.fetch("BOK_SYNC_DELAY", "4"),
    client: nil
  )
    @apply = apply
    @enhance = enhance
    @refetch = refetch
    @limit = limit
    @bok_id = bok_id
    @scope = scope
    @delay = delay
    @client = client
  end

  def call
    properties = select_candidates
    rows_out = []
    errors = []
    updated = enhanced = skipped = 0
    json_path = nil
    scraped_by_bok = {}

    if properties.empty?
      return Result.new(
        candidates: 0, refetched: 0, updated: 0, enhanced: 0,
        skipped: 0, errors: [], rows: [], json_path: nil
      )
    end

    json_path, scraped_by_bok = refetch!(properties) if @refetch

    properties.each_with_index do |property, index|
      old_plain = TruncatedDescription.plain_for(property)
      entry = {
        "bok_id" => property.bok_id,
        "id" => property.id,
        "title" => property.title,
        "source_url" => property.source_url,
        "old_len" => old_plain.length,
        "old_tail" => old_plain[-80..],
        "reason" => TruncatedDescription.ellipsis?(old_plain) ? "ellipsis" : "mid_cut"
      }

      unless @refetch
        entry["status"] = "candidate_only"
        skipped += 1
        rows_out << entry
        next
      end

      row = scraped_by_bok[property.bok_id.to_s] || scraped_by_bok[property.source_url.to_s]
      new_plain = TruncatedDescription.normalize(row&.dig("description"))
      entry["new_len"] = new_plain.length
      entry["new_tail"] = new_plain[-80..]

      if new_plain.blank?
        entry["status"] = "missing_scrape"
        skipped += 1
        rows_out << entry
        next
      end

      unless TruncatedDescription.better_replacement?(old_plain, new_plain)
        entry["status"] = "unchanged_or_not_better"
        skipped += 1
        rows_out << entry
        next
      end

      unless @apply
        entry["status"] = "dry_would_update"
        skipped += 1
        rows_out << entry
        puts "[#{index + 1}/#{properties.size}] #{property.bok_id} dry #{old_plain.length}→#{new_plain.length}"
        next
      end

      begin
        property.update!(description: new_plain)
        if property.respond_to?(:copy_review_notes)
          notes = property.copy_review_notes.is_a?(Hash) ? property.copy_review_notes.deep_dup : {}
          notes.delete("status")
          notes["repaired_truncated_at"] = Time.current.utc.iso8601
          property.update!(copy_needs_review: false, copy_review_notes: notes)
        end
        updated += 1
        entry["status"] = "updated_plain"

        if @enhance
          enhance_outcome = enhance!(property.reload)
          entry.merge!(enhance_outcome)
          enhanced += 1 if enhance_outcome["copy_applied"] || enhance_outcome["rich_applied"]
        end

        rows_out << entry
        puts "[#{index + 1}/#{properties.size}] #{property.bok_id} #{entry['status']} #{old_plain.length}→#{new_plain.length}"
      rescue StandardError => e
        errors << "#{property.bok_id || property.id}: #{e.class}: #{e.message}"
        entry["status"] = "error"
        entry["error"] = e.message
        rows_out << entry
      end
    end

    Result.new(
      candidates: properties.size,
      refetched: scraped_by_bok.size,
      updated: updated,
      enhanced: enhanced,
      skipped: skipped,
      errors: errors,
      rows: rows_out,
      json_path: json_path
    )
  end

  private

  def select_candidates
    relation = @scope || Property.where.not(bok_id: [ nil, "" ]).where.not(source_url: [ nil, "" ])
    relation = relation.where(bok_id: @bok_id) if @bok_id.present?

    found = []
    relation.find_each do |property|
      next unless TruncatedDescription.suspect_property?(property)

      found << property
      break if @limit && found.size >= @limit
    end
    found
  end

  def refetch!(properties)
    out_dir = Rails.root.join("scripts/bok_sync_data")
    out_dir.mkpath
    urls_file = out_dir.join("repair_truncated_urls_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}.txt")
    urls = properties.map { |p| p.source_url.to_s.strip }.reject(&:blank?).uniq
    urls_file.write(urls.join("\n") + "\n")

    before = Dir.glob(out_dir.join("houses_last_month_*.json")).map { |p| [ p, File.mtime(p) ] }.to_h

    cmd = [
      "python3", Rails.root.join("scripts/bok_gentle_listings_sync.py").to_s,
      "--urls-file", urls_file.to_s,
      "--refetch",
      "--days", ENV.fetch("BOK_SYNC_DAYS", "3650"),
      "--delay", @delay.to_s,
      "--out-dir", out_dir.to_s,
      "--max-details", urls.size.to_s
    ]

    puts "Refetching #{urls.size} BOK detail page(s)…"
    puts cmd.join(" ")
    ok = system(*cmd)
    raise Error, "Scraper failed (#{$?.exitstatus})" unless ok

    newest = Dir.glob(out_dir.join("houses_last_month_*.json")).max_by { |p| File.mtime(p) }
    raise Error, "No sync JSON written" unless newest
    created = Dir.glob(out_dir.join("houses_last_month_*.json")).select { |p|
      before[p].nil? || File.mtime(p) > before[p]
    }.max_by { |p| File.mtime(p) }
    path = created || newest

    rows = JSON.parse(File.read(path))
    by_key = {}
    rows.each do |row|
      by_key[row["bok_id"].to_s] = row if row["bok_id"].present?
      by_key[row["url"].to_s] = row if row["url"].present?
    end
    [ path.to_s, by_key ]
  end

  def enhance!(property)
    out = { "copy_applied" => false, "rich_applied" => false }

    if listing_copy_enabled?
      outcome = ListingCopyApplier.call(property, client: openai_client)
      out["copy_applied"] = outcome.applied?
      out["copy_error"] = outcome.error if outcome.error
      property.reload
    end

    previous = ENV["LISTING_COPY_RICH_HTML"]
    ENV["LISTING_COPY_RICH_HTML"] = "1"
    begin
      rich = ListingDescriptionRichFormatter.call(property, client: openai_client, apply: true)
      out["rich_applied"] = rich.applied?
      out["rich_error"] = rich.error if rich.error
    ensure
      if previous.nil?
        ENV.delete("LISTING_COPY_RICH_HTML")
      else
        ENV["LISTING_COPY_RICH_HTML"] = previous
      end
    end
    out
  end

  def openai_client
    @client || OpenaiClient.new
  end

  def listing_copy_enabled?
    return false if ENV["BOK_APPLY_LISTING_COPY"].to_s == "0"
    return true if ENV["BOK_APPLY_LISTING_COPY"].to_s == "1"

    openai_client.configured?
  end
end
