namespace :gallery do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Backfill hosted gallery images (download → optional enhance → attach).
    INLINE=1 runs in this process.
    CONCURRENT_PROPERTIES = independent listing workers (default = ESRGAN slot count when
    enhance is on). Each worker grabs a listing from a shared queue, processes/syncs it alone,
    then immediately pulls the next — no waiting on peer listings.
    GALLERY_ENHANCE=1 enables prep|GPU pipeline. LIMIT / BOK_ID / FORCE / ONLY_NEEDED.
  DESC
  task backfill: :environment do
    $stdout.sync = true
    $stderr.sync = true
    inline = ENV["INLINE"].to_s.match?(/\A(1|true|yes)\z/i)
    force = ENV["FORCE"].to_s.match?(/\A(1|true|yes)\z/i)
    only_needed = !force
    only_needed = false if ENV["ONLY_NEEDED"].to_s.match?(/\A(0|false|no)\z/i)
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }

    slot_n = PropertyGalleryEnhancer.enabled? ? PropertyGalleryEnhancer.esrgan_slots.size : 1
    default_workers = [ slot_n, 1 ].max
    concurrent = if ENV["CONCURRENT_PROPERTIES"].present?
      [ Integer(ENV["CONCURRENT_PROPERTIES"]), 1 ].max
    else
      default_workers
    end
    concurrent = 1 unless inline

    previous_analyzers = ActiveStorage.analyzers.dup if inline
    ActiveStorage.analyzers = [] if inline && PropertyGalleryEnhancer.enabled?

    scope = Property.order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    if ENV["PROPERTY_IDS"].present?
      ids = ENV["PROPERTY_IDS"].to_s.split(/[,\s]+/).map(&:presence).compact.map!(&:to_i)
      scope = scope.where(id: ids)
    elsif ENV["PROPERTY_IDS_FILE"].present?
      raw = File.read(ENV["PROPERTY_IDS_FILE"])
      ids = raw.start_with?("[") ? JSON.parse(raw) : raw.split(/[,\s]+/)
      scope = scope.where(id: Array(ids).map(&:to_i))
    end

    puts "Gallery ingest backfill (#{inline ? "inline" : "enqueue"}, only_needed=#{only_needed}, " \
         "force=#{force}, enhance=#{PropertyGalleryEnhancer.enabled?}, " \
         "esrgan=#{PropertyGalleryEnhancer.esrgan_enabled?}, concurrent_properties=#{concurrent}, " \
         "slots=#{PropertyGalleryEnhancer.esrgan_slots.map(&:id).join(",")}, limit=#{limit || "all"})…"
    puts "  model: #{concurrent} independent listing workers pull from a shared job queue"

    if inline && PropertyGalleryEnhancer.esrgan_enabled?
      EsrganGpuFanout.reset_shared!
      begin
        EsrganGpuFanout.shared.send(:warmup_hosts!)
        puts "  ESRGAN hosts warm: #{EsrganGpuFanout.shared.stats_snapshot[:hosts_warm].join(",")}"
      rescue StandardError => e
        puts "  ESRGAN warmup warning: #{e.class}: #{e.message}"
      end
    end

    queued = 0
    skipped = 0
    scanned = 0
    attached = 0
    enhanced = 0
    errors = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    mutex = Mutex.new
    last_rate_log = started
    accepted = 0

    log_rate = lambda do |force_log: false|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !force_log && (now - last_rate_log) < 60

      wall = now - started
      rate = wall.positive? ? (enhanced / (wall / 60.0)) : 0.0
      puts "  …rate attached=#{attached} enhanced=#{enhanced} wall_s=#{wall.round(0)} " \
           "imgs_per_min=#{rate.round(1)}"
      last_rate_log = now
    end

    process_property = lambda do |property|
      ActiveRecord::Base.connection_pool.with_connection do
        if force && property.gallery_images.attached?
          purged = property.gallery_images.count
          property.gallery_images.purge
          puts "  purged #{purged} hosted images for ##{property.id} #{property.bok_id || property.slug}"
        end
        result = PropertyGalleryIngestor.call(property)
        urls = property.gallery_image_urls
        mutex.synchronize do
          attached += result[:attached].to_i
          enhanced += result[:enhanced].to_i
          errors += result[:errors].size
          queued += 1
          puts "  [#{queued}] ##{property.id} #{property.bok_id || property.slug} " \
               "attached=#{result[:attached]} enhanced=#{result[:enhanced]} " \
               "skipped=#{result[:skipped]} errors=#{result[:errors].size} " \
               "imgs_per_min=#{result[:imgs_per_min].to_f.round(1)} (#{urls.size} urls)"
          result[:errors].first(2).each { |msg| puts "    ERR #{msg}" }
          log_rate.call
        end
      end
    rescue StandardError => e
      mutex.synchronize do
        errors += 1
        queued += 1
        puts "  [#{queued}] FAIL ##{property.id}: #{e.class}: #{e.message}"
      end
    end

    if inline && concurrent > 1
      # Shared job pool: workers never wait on each other — grab, finish, grab next.
      work_queue = SizedQueue.new([ concurrent * 4, 16 ].max)
      workers = Array.new(concurrent) do |i|
        Thread.new do
          Thread.current.name = "gallery-listing-#{i}"
          loop do
            property_id = work_queue.pop
            break if property_id.nil?

            property = ActiveRecord::Base.connection_pool.with_connection { Property.find_by(id: property_id) }
            process_property.call(property) if property
          end
        end
      end

      scope.find_each do |property|
        scanned += 1
        next (skipped += 1) if property.gallery_image_urls.empty?
        next (skipped += 1) if only_needed && !property.gallery_ingest_needed?
        break if limit && accepted >= limit

        work_queue << property.id
        accepted += 1
      end
      concurrent.times { work_queue << nil }
      workers.each(&:join)
    else
      scope.find_each do |property|
        break if limit && queued >= limit

        scanned += 1
        urls = property.gallery_image_urls
        next (skipped += 1) if urls.empty?
        next (skipped += 1) if only_needed && !property.gallery_ingest_needed?

        if inline
          process_property.call(property)
        else
          PropertyImageIngestJob.perform_later(property.id)
          queued += 1
          puts "  queued ##{property.id} #{property.bok_id || property.slug} (#{urls.size} urls)"
        end
      end
    end

    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    rate = elapsed.positive? ? (enhanced / (elapsed / 60.0)) : 0.0
    log_rate.call(force_log: true)
    puts
    puts "Done. scanned=#{scanned} processed=#{queued} skipped=#{skipped} " \
         "attached=#{attached} enhanced=#{enhanced} errors=#{errors} " \
         "elapsed=#{elapsed}s imgs_per_min=#{rate.round(1)}"
  ensure
    ActiveStorage.analyzers = previous_analyzers if inline && previous_analyzers
  end
end
