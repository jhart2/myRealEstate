namespace :gallery do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Backfill hosted gallery images (download → enhance → attach). Default enqueues
    FIFO gallery_enhance jobs (does not gate listing publish).
    INLINE=1 runs synchronously in this process (best for local one-shot).
    LIMIT=100 BOK_ID=BOK-123 ONLY_NEEDED=1 (default) FORCE=1 to re-ingest even if hosted.
    GALLERY_ENHANCE=0 to store originals; GALLERY_ENHANCE_ESRGAN=0 to skip bosgame.
  DESC
  task backfill: :environment do
    $stdout.sync = true
    $stderr.sync = true
    inline = ENV["INLINE"].to_s.match?(/\A(1|true|yes)\z/i)
    force = ENV["FORCE"].to_s.match?(/\A(1|true|yes)\z/i)
    only_needed = !force
    only_needed = false if ENV["ONLY_NEEDED"].to_s.match?(/\A(0|false|no)\z/i)
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }

    scope = Property.order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?

    mode = inline ? "inline" : "enqueue"
    puts "Gallery ingest backfill (#{mode}, only_needed=#{only_needed}, force=#{force}, " \
         "enhance=#{PropertyGalleryEnhancer.enabled?}, esrgan=#{PropertyGalleryEnhancer.esrgan_enabled?}, " \
         "limit=#{limit || "all"})…"

    queued = 0
    skipped = 0
    scanned = 0
    attached = 0
    enhanced = 0
    errors = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    scope.find_each do |property|
      break if limit && queued >= limit

      scanned += 1
      urls = property.gallery_image_urls
      if urls.empty?
        skipped += 1
        next
      end

      if only_needed && !property.gallery_ingest_needed?
        skipped += 1
        next
      end

      if inline
        begin
          # FORCE replaces hosted blobs so enhance/re-ingest can run again.
          if force && property.gallery_images.attached?
            purged = property.gallery_images.count
            property.gallery_images.purge
            puts "  purged #{purged} hosted images for ##{property.id} #{property.bok_id || property.slug}"
          end

          result = PropertyGalleryIngestor.call(property)
          attached += result[:attached].to_i
          enhanced += result[:enhanced].to_i
          errors += result[:errors].size
          queued += 1
          puts "  [#{queued}] ##{property.id} #{property.bok_id || property.slug} " \
               "attached=#{result[:attached]} enhanced=#{result[:enhanced]} " \
               "skipped=#{result[:skipped]} errors=#{result[:errors].size} (#{urls.size} urls)"
          result[:errors].first(2).each { |msg| puts "    ERR #{msg}" }
        rescue StandardError => e
          errors += 1
          queued += 1
          puts "  [#{queued}] FAIL ##{property.id} #{property.bok_id || property.slug}: #{e.class}: #{e.message}"
        end
      else
        PropertyImageIngestJob.perform_later(property.id)
        queued += 1
        puts "  queued ##{property.id} #{property.bok_id || property.slug} (#{urls.size} urls)"
      end
    end

    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    puts
    puts "Done. scanned=#{scanned} processed=#{queued} skipped=#{skipped} " \
         "attached=#{attached} enhanced=#{enhanced} errors=#{errors} elapsed=#{elapsed}s"
    unless inline
      puts "Jobs run via Solid Queue / bin/jobs (or async adapter in this environment)."
    end
  end
end
