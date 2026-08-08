require "test_helper"
require "stringio"

class PropertyGalleryDisplayTest < ActiveSupport::TestCase
  setup do
    @prev_mode = ENV["GALLERY_DISPLAY_MODE"]
    Agent.delete_all
    Property.delete_all

    @agent = Agent.create!(
      name: "Display Agent",
      title: "Agent",
      email: "display-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
    @cdn_a = "https://cdn.example.com/a.jpg"
    @cdn_b = "https://cdn.example.com/b.jpg"
    @property = Property.create!(
      agent: @agent,
      title: "Display Home",
      slug: "display-home-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "1 Test St",
      city: "Port of Spain",
      state: "Trinidad",
      zip: "",
      price_cents: 100_000_00,
      image_url: @cdn_a,
      image_urls: [ @cdn_a, @cdn_b ]
    )
  end

  teardown do
    if @prev_mode.nil?
      ENV.delete("GALLERY_DISPLAY_MODE")
    else
      ENV["GALLERY_DISPLAY_MODE"] = @prev_mode
    end
  end

  test "enhanced_or_cdn uses CDN until enhanced blob exists" do
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_or_cdn"

    assert_equal [ @cdn_a, @cdn_b ], @property.display_gallery_image_urls
    assert_equal @cdn_a, @property.display_image_url
    assert @property.image_present?

    raw = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("raw-bytes"),
      filename: "a.jpg",
      content_type: "image/jpeg",
      metadata: { "source_url" => @cdn_a, "source_urls" => [ @cdn_a ], "enhanced" => false }
    )
    @property.gallery_images_attachments.create!(blob_id: raw.id)
    assert_equal [ @cdn_a, @cdn_b ], @property.reload.display_gallery_image_urls

    polished = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("enhanced-bytes"),
      filename: "a.jpg",
      content_type: "image/jpeg",
      metadata: { "source_url" => @cdn_a, "source_urls" => [ @cdn_a ], "enhanced" => true }
    )
    @property.gallery_images_attachments.destroy_all
    @property.gallery_images_attachments.create!(blob_id: polished.id)

    urls = @property.reload.display_gallery_image_urls
    assert_match(%r{\A/rails/active_storage/}, urls.first)
    assert_equal @cdn_b, urls.second
  end

  test "enhanced_only hides unenhanced hosted blobs" do
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_only"
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("raw"),
      filename: "a.jpg",
      content_type: "image/jpeg",
      metadata: { "source_url" => @cdn_a, "source_urls" => [ @cdn_a ] }
    )
    @property.gallery_images_attachments.create!(blob_id: blob.id)

    assert_empty @property.reload.display_gallery_image_urls
    assert_nil @property.display_image_url
  end
end
