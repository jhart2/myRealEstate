# Downloads remote listing gallery URLs into Active Storage (local disk or GCS).
# On sync path: download → enhance (darktable + IM + ESRGAN) → attach.
# Idempotent: skips URLs already attached via blob metadata source_url(s).
# Identical bytes (Active Storage checksum dedupe) reuse one blob and merge source URLs.
# Listing publish is not gated on this job — importer enqueues FIFO and continues.
require "net/http"
require "stringio"
require "uri"

class PropertyGalleryIngestor
  class DownloadError < StandardError; end

  MAX_BYTES = 25.megabytes
  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 60
  USER_AGENT = "TTRealtyImageIngest/1.0 (+https://ttrealty.com)".freeze

  def self.call(property, downloader: method(:download), enhancer: PropertyGalleryEnhancer.method(:enhance_payload))
    new(property, downloader: downloader, enhancer: enhancer).call
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

  # WP galleries sometimes include Unicode spaces (e.g. U+202F before AM/PM).
  # Ruby's URI parser requires ASCII, so percent-encode non-ASCII codepoints.
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

  def initialize(property, downloader:, enhancer: PropertyGalleryEnhancer.method(:enhance_payload))
    @property = property
    @downloader = downloader
    @enhancer = enhancer
  end

  def call
    urls = @property.gallery_image_urls
    return { attached: 0, skipped: 0, purged: 0, enhanced: 0, errors: [] } if urls.empty?

    existing = attachments_by_source_url
    keep = urls.to_set
    purged = purge_stale!(existing, keep)

    attached = 0
    skipped = 0
    enhanced = 0
    errors = []

    urls.each do |url|
      if existing[url]
        skipped += 1
        next
      end

      begin
        payload = @enhancer.call(@downloader.call(url))
        meta = { "source_url" => url, "source_urls" => [ url ] }
        if payload[:metadata].is_a?(Hash)
          payload[:metadata].each { |key, value| meta[key.to_s] = value }
        end
        enhanced += 1 if ActiveModel::Type::Boolean.new.cast(meta["enhanced"])

        blob = ActiveStorage::Blob.create_and_upload!(
          io: payload.fetch(:io),
          filename: payload.fetch(:filename),
          content_type: payload.fetch(:content_type),
          metadata: meta
        )

        if already_attached?(blob.id)
          merge_source_url!(blob, url)
          existing[url] = true
          skipped += 1
          next
        end

        # Use blob_id (not attach(blob)): gallery_images.attach rebuilds the full
        # set via CreateMany, and in long-running tasks after a code reload the
        # Blob class identity can diverge so `when ActiveStorage::Blob` fails.
        attach_blob!(blob)
        merge_source_url!(blob, url)
        existing[url] = true
        attached += 1
      rescue ActiveRecord::RecordNotUnique
        # Same blob already attached to this gallery (unique index race).
        merge_source_url!(blob, url) if blob
        existing[url] = true
        skipped += 1
      rescue DownloadError, ActiveRecord::RecordInvalid, ActiveStorage::IntegrityError => e
        errors << "#{url}: #{e.message}"
        Rails.logger.warn("[gallery_ingest] property=#{@property.id} #{e.message}")
      end
    end

    { attached: attached, skipped: skipped, purged: purged, enhanced: enhanced, errors: errors }
  end

  private

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
      self.class.source_urls_for(attachment.blob).each do |src|
        map[src] = attachment
      end
    end
    map
  end

  def purge_stale!(existing, keep)
    # Only purge attachments whose *all* source URLs were dropped from the gallery.
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
end
