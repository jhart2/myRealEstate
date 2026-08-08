# FIFO gallery ingest+enhance for one listing. Enqueued during BOK sync without
# blocking listing create/update (no publish gating).
#
# Queue `gallery_enhance` is processed by a single-threaded Solid Queue worker
# so listings drain in order; ESRGAN also takes a process flock.
class PropertyImageIngestJob < ApplicationJob
  queue_as :gallery_enhance

  retry_on PropertyGalleryIngestor::DownloadError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(property_id)
    property = Property.find_by(id: property_id)
    return unless property

    result = PropertyGalleryIngestor.call(property)
    Rails.logger.info(
      "[gallery_enhance] property=#{property.id} bok=#{property.bok_id} " \
      "attached=#{result[:attached]} enhanced=#{result[:enhanced]} " \
      "skipped=#{result[:skipped]} purged=#{result[:purged]} errors=#{result[:errors].size}"
    )
    result
  end
end
