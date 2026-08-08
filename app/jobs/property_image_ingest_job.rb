# Gallery ingest (+ optional enhance) for one listing. Enqueued during BOK sync
# without blocking listing create/update (no publish gating).
#
# Queue `gallery_enhance` when polish is enabled; otherwise `gallery_ingest`.
class PropertyImageIngestJob < ApplicationJob
  def self.queue_name
    if PropertyGalleryEnhancer.enabled?
      "gallery_enhance"
    else
      "gallery_ingest"
    end
  end

  queue_as { self.class.queue_name }

  retry_on PropertyGalleryIngestor::DownloadError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(property_id)
    property = Property.find_by(id: property_id)
    return unless property

    result = PropertyGalleryIngestor.call(property)
    Rails.logger.info(
      "[gallery_ingest] property=#{property.id} bok=#{property.bok_id} " \
      "attached=#{result[:attached]} enhanced=#{result[:enhanced]} " \
      "skipped=#{result[:skipped]} purged=#{result[:purged]} errors=#{result[:errors].size}"
    )
    result
  end
end
