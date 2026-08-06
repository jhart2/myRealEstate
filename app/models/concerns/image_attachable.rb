module ImageAttachable
  extend ActiveSupport::Concern

  included do
    has_one_attached :image
    attr_accessor :remove_image

    validate :acceptable_image
    after_save :purge_image_if_requested
  end

  def display_image_url
    if image.attached?
      Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true)
    else
      self[:image_url].presence
    end
  end

  def image_present?
    image.attached? || self[:image_url].present?
  end

  private

  def acceptable_image
    return unless image.attached?

    blob = image.blob
    return unless blob&.content_type.present?

    unless blob.content_type.in?(%w[image/jpeg image/png image/webp image/gif])
      errors.add(:image, "must be a JPEG, PNG, WebP, or GIF")
    end

    if blob.byte_size.to_i > 10.megabytes
      errors.add(:image, "must be smaller than 10MB")
    end
  end

  def purge_image_if_requested
    return unless ActiveModel::Type::Boolean.new.cast(remove_image)

    image.purge_later if image.attached?
    update_column(:image_url, nil) if has_attribute?(:image_url) && self[:image_url].present?
  end
end
