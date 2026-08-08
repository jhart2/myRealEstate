# Downloads remote listing gallery URLs into Active Storage (local disk or GCS).
# When GALLERY_ENHANCE=1: download → CPU prep → ESRGAN fanout → attach.
# Otherwise: download → attach originals only.
# Idempotent: skips URLs already attached via blob metadata source_url(s).
#
# Enhance pipeline (prep ahead of GPU):
#   Stage A: download + darktable + ImageMagick (prep pool, process-wide gate)
#   Stage B: EsrganGpuFanout slots (GPU consumers only)
#   Stage C: JPEG finalize + GCS upload (upload pool — does not stall GPU)
require "net/http"
require "stringio"
require "uri"

class PropertyGalleryIngestor
  class DownloadError < StandardError; end

  MAX_BYTES = 25.megabytes
  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 60
  USER_AGENT = "TTRealtyImageIngest/1.0 (+https://ttrealty.com)".freeze

  def self.call(property, downloader: method(:download), enhancer: PropertyGalleryEnhancer.method(:enhance_payload), concurrency: nil)
    new(property, downloader: downloader, enhancer: enhancer, concurrency: concurrency).call
  end

  def self.download(url)
    uri = parse_http_uri!(url)

    response = nil
    redirects = 0
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = http.request(request)

      break unless response.is_a?(Net::HTTPRedirection)
      redirects += 1
      raise DownloadError, "too many redirects" if redirects > 5

      location = response["location"].to_s
      raise DownloadError, "redirect without location" if location.blank?

      uri = parse_http_uri!(URI.join(uri.to_s, ascii_url(location)).to_s)
    end

    raise DownloadError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    body = response.body.to_s
    raise DownloadError, "empty body" if body.blank?
    raise DownloadError, "too large (#{body.bytesize} bytes)" if body.bytesize > MAX_BYTES

    content_type = response["content-type"].to_s.split(";").first.to_s.strip.presence
    content_type = Marcel::MimeType.for(StringIO.new(body), name: File.basename(uri.path.to_s)) if content_type.blank?
    unless content_type.to_s.start_with?("image/")
      raise DownloadError, "not an image (#{content_type.presence || "unknown"})"
    end

    {
      io: StringIO.new(body),
      filename: filename_for(uri, content_type),
      content_type: content_type
    }
  rescue DownloadError
    raise
  rescue StandardError => e
    raise DownloadError, e.message
  end

  def self.ascii_url(url)
    str = url.to_s.strip.unicode_normalize(:nfc)
    return str if str.ascii_only?

    str.chars.map do |ch|
      next ch if ch.ascii_only?

      ch.bytes.map { |byte| format("%%%02X", byte) }.join
    end.join
  end

  def self.parse_http_uri!(url)
    uri = URI.parse(ascii_url(url))
    raise DownloadError, "invalid URL" unless uri.is_a?(URI::HTTP)

    uri
  rescue URI::InvalidURIError => e
    raise DownloadError, e.message
  end

  def self.filename_for(uri, content_type)
    base = File.basename(uri.path.to_s).presence
    base = "image" if base.blank? || base == "/"
    return base if File.extname(base).present?

    ext =
      case content_type
      when "image/jpeg" then ".jpg"
      when "image/png" then ".png"
      when "image/webp" then ".webp"
      when "image/gif" then ".gif"
      else ".img"
      end
    "#{base}#{ext}"
  end

  def self.source_urls_for(blob)
    meta = blob.metadata || {}
    urls = Array(meta["source_urls"]).presence || Array(meta["source_url"])
    urls.map(&:to_s).reject(&:blank?).uniq
  end

  def self.default_prep_concurrency
    if ENV["GALLERY_PREP_CONCURRENCY"].present?
      return [ Integer(ENV["GALLERY_PREP_CONCURRENCY"]), 1 ].max
    end
    if ENV["GALLERY_ENHANCE_CONCURRENCY"].present?
      return [ Integer(ENV["GALLERY_ENHANCE_CONCURRENCY"]), 1 ].max
    end
    if ENV["GALLERY_INGEST_CONCURRENCY"].present?
      return [ Integer(ENV["GALLERY_INGEST_CONCURRENCY"]), 1 ].max
    end

    return 1 unless PropertyGalleryEnhancer.enabled?

    n = PropertyGalleryEnhancer.esrgan_slots.size
    [ [ n * 2, 4 ].max, 8 ].min
  end

  def self.default_concurrency
    default_prep_concurrency
  end

  def self.prep_gate
    @prep_gate_mutex ||= Mutex.new
    @prep_gate_mutex.synchronize do
      limit = default_prep_concurrency
      if @prep_gate.nil? || @prep_gate_limit != limit
        @prep_gate = Queue.new
        limit.times { @prep_gate << true }
        @prep_gate_limit = limit
      end
      @prep_gate
    end
  end

  def self.with_prep_slot
    gate = prep_gate
    gate.pop
    yield
  ensure
    gate << true if gate
  end

  def initialize(property, downloader:, enhancer: PropertyGalleryEnhancer.method(:enhance_payload), concurrency: nil)
    @property = property
    @downloader = downloader
    @enhancer = enhancer
    @concurrency = concurrency
  end

  def call
    urls = @property.gallery_image_urls
    return empty_result if urls.empty?

    existing = attachments_by_source_url
    keep = urls.to_set
    purged = purge_stale!(existing, keep)

    attached = 0
    skipped = 0
    enhanced = 0
    errors = []
    timings = []

    missing = []
    urls.each do |url|
      if existing[url]
        skipped += 1
      else
        missing << url
      end
    end

    return empty_result(skipped: skipped, purged: purged) if missing.empty?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    prepared =
      if use_gpu_pipeline?
        prepare_missing_pipelined(missing, resolve_concurrency, errors, timings)
      elsif resolve_concurrency <= 1
        prepare_missing_serial(missing, errors)
      else
        prepare_missing_parallel(missing, resolve_concurrency, errors)
      end

    missing.each do |url|
      item = prepared[url]
      next unless item
      next if item[:error]

      blob = item[:blob]
      begin
        if already_attached?(blob.id)
          merge_source_url!(blob, url)
          existing[url] = true
          skipped += 1
          next
        end

        attach_blob!(blob)
        merge_source_url!(blob, url)
        existing[url] = true
        attached += 1
        enhanced += 1 if item[:enhanced]
      rescue ActiveRecord::RecordNotUnique
        merge_source_url!(blob, url) if blob
        existing[url] = true
        skipped += 1
      rescue ActiveRecord::RecordInvalid, ActiveStorage::IntegrityError => e
        errors << "#{url}: #{e.message}"
        Rails.logger.warn("[gallery_ingest] property=#{@property.id} #{e.message}")
      end
    end

    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    imgs_per_min = wall.positive? ? (enhanced / (wall / 60.0)) : 0.0
    if timings.any?
      Rails.logger.info(
        "[gallery_ingest] property=#{@property.id} pipeline enhanced=#{enhanced} " \
        "wall_s=#{wall.round(1)} imgs_per_min=#{imgs_per_min.round(1)} " \
        "prep_ms_p50=#{percentile(timings.map { |t| t[:prep_ms] }, 0.5)} " \
        "queue_wait_ms_p50=#{percentile(timings.map { |t| t[:queue_wait_ms] }, 0.5)} " \
        "esrgan_ms_p50=#{percentile(timings.map { |t| t[:esrgan_ms] }, 0.5)}"
      )
    end

    {
      attached: attached,
      skipped: skipped,
      purged: purged,
      enhanced: enhanced,
      errors: errors,
      wall_s: wall,
      imgs_per_min: imgs_per_min,
      timings: timings
    }
  end

  private

  def empty_result(skipped: 0, purged: 0)
    { attached: 0, skipped: skipped, purged: purged, enhanced: 0, errors: [], wall_s: 0.0, imgs_per_min: 0.0, timings: [] }
  end

  def use_gpu_pipeline?
    return false unless PropertyGalleryEnhancer.enabled?
    return false unless PropertyGalleryEnhancer.esrgan_enabled?
    return false if ENV["GALLERY_ENHANCE_PIPELINE"].to_s.match?(/\A(0|false|no|off)\z/i)

    @enhancer == PropertyGalleryEnhancer.method(:enhance_payload)
  end

  def resolve_concurrency
    return [ Integer(@concurrency), 1 ].max unless @concurrency.nil?

    self.class.default_prep_concurrency
  end

  def prepare_missing_serial(missing, errors)
    prepared = {}
    missing.each { |url| prepared[url] = prepare_one(url, errors) }
    prepared
  end

  def prepare_missing_parallel(missing, workers, errors)
    queue = Queue.new
    missing.each { |url| queue << url }
    prepared = {}
    prepared_mutex = Mutex.new
    errors_mutex = Mutex.new

    threads = Array.new(workers) do
      Thread.new do
        loop do
          url = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          thread_errors = []
          outcome = prepare_one(url, thread_errors)
          prepared_mutex.synchronize { prepared[url] = outcome }
          errors_mutex.synchronize { errors.concat(thread_errors) } if thread_errors.any?
        end
      end
    end
    threads.each(&:join)
    prepared
  end

  def prepare_missing_pipelined(missing, prep_workers, errors, timings)
    url_queue = Queue.new
    missing.each { |url| url_queue << url }

    ready = Queue.new
    upload_q = Queue.new
    prepared = {}
    prepared_mutex = Mutex.new
    errors_mutex = Mutex.new
    timings_mutex = Mutex.new

    prep_n = [ prep_workers, 1 ].max
    gpu_n = [ PropertyGalleryEnhancer.esrgan_slots.size, 1 ].max
    upload_n = [ Integer(ENV.fetch("GALLERY_UPLOAD_CONCURRENCY", "4")), 1 ].max

    prep_threads = Array.new(prep_n) do
      Thread.new do
        loop do
          url = begin
            url_queue.pop(true)
          rescue ThreadError
            break
          end
          begin
            payload = @downloader.call(url)
            staged = self.class.with_prep_slot { PropertyGalleryEnhancer.stage_cpu!(payload) }
            ready << { url: url, staged: staged, ready_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          rescue DownloadError, PropertyGalleryEnhancer::Error, StandardError => e
            errors_mutex.synchronize { errors << "#{url}: #{e.message}" }
            Rails.logger.warn("[gallery_ingest] property=#{@property.id} prep #{e.message}")
            prepared_mutex.synchronize { prepared[url] = { error: true } }
          end
        end
      end
    end

    gpu_threads = Array.new(gpu_n) do
      Thread.new do
        loop do
          item = ready.pop
          break if item.nil?

          url = item[:url]
          staged = item[:staged]
          queue_wait_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - item[:ready_at]) * 1000).round
          begin
            esrgan_png = nil
            esrgan_ms = nil
            unless staged.skip_esrgan
              esrgan_path = Pathname(staged.work_dir).join("03_esrgan.png")
              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              result = EsrganGpuFanout.enhance!(staged.esrgan_in, esrgan_path, raise_on_error: false)
              esrgan_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
              if result&.ok
                esrgan_png = esrgan_path
              else
                Rails.logger.warn(
                  "[gallery_ingest] property=#{@property.id} ESRGAN skipped — #{result&.error || "unknown"}"
                )
              end
            end
            upload_q << {
              url: url, staged: staged, esrgan_png: esrgan_png,
              esrgan_ms: esrgan_ms, queue_wait_ms: queue_wait_ms
            }
          rescue StandardError => e
            staged.cleanup! if staged
            errors_mutex.synchronize { errors << "#{url}: #{e.message}" }
            prepared_mutex.synchronize { prepared[url] = { error: true } }
          end
        end
      end
    end

    upload_threads = Array.new(upload_n) do
      Thread.new do
        loop do
          item = upload_q.pop
          break if item.nil?

          outcome = upload_staged_item(item, errors_mutex, errors, timings_mutex, timings)
          prepared_mutex.synchronize { prepared[item[:url]] = outcome }
        end
      end
    end

    prep_threads.each(&:join)
    gpu_n.times { ready << nil }
    gpu_threads.each(&:join)
    upload_n.times { upload_q << nil }
    upload_threads.each(&:join)
    prepared
  end

  def upload_staged_item(item, errors_mutex, errors, timings_mutex, timings)
    url = item[:url]
    staged = item[:staged]
    prep_ms = staged.prep_ms
    payload = PropertyGalleryEnhancer.finalize_staged!(
      staged,
      esrgan_png: item[:esrgan_png],
      esrgan_ms: item[:esrgan_ms],
      queue_wait_ms: item[:queue_wait_ms]
    )
    timing = { prep_ms: prep_ms, queue_wait_ms: item[:queue_wait_ms], esrgan_ms: item[:esrgan_ms] }
    timings_mutex.synchronize { timings << timing }

    meta = { "source_url" => url, "source_urls" => [ url ] }
    payload[:metadata].each { |k, v| meta[k.to_s] = v } if payload[:metadata].is_a?(Hash)
    was_enhanced = ActiveModel::Type::Boolean.new.cast(meta["enhanced"])

    blob = ActiveRecord::Base.connection_pool.with_connection do
      ActiveStorage::Blob.create_and_upload!(
        io: payload.fetch(:io),
        filename: payload.fetch(:filename),
        content_type: payload.fetch(:content_type),
        metadata: meta
      )
    end
    { blob: blob, enhanced: was_enhanced, timing: timing }
  rescue StandardError => e
    staged.cleanup! if staged
    errors_mutex.synchronize { errors << "#{url}: #{e.message}" }
    { error: true }
  end

  def prepare_one(url, errors)
    raw = @downloader.call(url)
    payload = @enhancer.call(raw)
    meta = { "source_url" => url, "source_urls" => [ url ] }
    payload[:metadata].each { |k, v| meta[k.to_s] = v } if payload[:metadata].is_a?(Hash)
    was_enhanced = ActiveModel::Type::Boolean.new.cast(meta["enhanced"])

    blob = ActiveRecord::Base.connection_pool.with_connection do
      ActiveStorage::Blob.create_and_upload!(
        io: payload.fetch(:io),
        filename: payload.fetch(:filename),
        content_type: payload.fetch(:content_type),
        metadata: meta
      )
    end
    { blob: blob, enhanced: was_enhanced }
  rescue DownloadError, ActiveRecord::RecordInvalid, ActiveStorage::IntegrityError => e
    errors << "#{url}: #{e.message}"
    Rails.logger.warn("[gallery_ingest] property=#{@property.id} #{e.message}")
    { error: true }
  end

  def already_attached?(blob_id)
    @property.gallery_images_attachments.exists?(blob_id: blob_id)
  end

  def attach_blob!(blob)
    @property.gallery_images_attachments.create!(blob_id: blob.id)
  end

  def merge_source_url!(blob, url)
    urls = (self.class.source_urls_for(blob) + [ url ]).uniq
    blob.update!(metadata: blob.metadata.merge("source_url" => urls.first, "source_urls" => urls))
  end

  def attachments_by_source_url
    map = {}
    @property.gallery_images_attachments.includes(:blob).find_each do |attachment|
      self.class.source_urls_for(attachment.blob).each { |src| map[src] = attachment }
    end
    map
  end

  def purge_stale!(existing, keep)
    stale = @property.gallery_images_attachments.includes(:blob).select do |attachment|
      sources = self.class.source_urls_for(attachment.blob)
      sources.present? && sources.none? { |src| keep.include?(src) }
    end
    stale.each do |attachment|
      self.class.source_urls_for(attachment.blob).each { |src| existing.delete(src) }
      attachment.purge
    end
    stale.size
  end

  def percentile(values, p)
    arr = values.compact.map(&:to_f).sort
    return nil if arr.empty?

    arr[[ ((arr.size - 1) * p).round, arr.size - 1 ].min].round
  end
end
