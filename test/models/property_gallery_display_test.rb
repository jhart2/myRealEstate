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
    assert_equal @cdn_a, @property.listing_cover_url
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
    # Index/map covers stay on CDN even when an enhanced blob exists.
    assert_equal @cdn_a, @property.listing_cover_url
    assert_equal @cdn_a, @property.as_map_json[:image]
  end

  test "listing_cover_url and as_map_json avoid gallery attachment queries" do
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_or_cdn"
    5.times do |i|
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("bytes-#{i}"),
        filename: "img-#{i}.jpg",
        content_type: "image/jpeg",
        metadata: { "source_url" => @cdn_a, "source_urls" => [ @cdn_a ], "enhanced" => true }
      )
      @property.gallery_images_attachments.create!(blob_id: blob.id)
    end
    @property.reload

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] !~ /SCHEMA|TRANSACTION/i }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      cover = @property.listing_cover_url
      json = @property.as_map_json
      assert_equal @cdn_a, cover
      assert_equal @cdn_a, json[:image]
    end

    attachment_queries = queries.count { |sql| sql.match?(/active_storage_attachments|active_storage_blobs/i) }
    assert_equal 0, attachment_queries, "expected no Active Storage queries, got:\n#{queries.join("\n")}"
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

  test "gallery_image_urls percent-encodes unicode spaces in CDN paths" do
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_or_cdn"
    nbsp_url = "https://cdn.example.com/Screenshot-at-9.34.23\u202fam.png"
    @property.update!(image_url: nbsp_url, image_urls: [ nbsp_url ])

    urls = @property.reload.gallery_image_urls
    assert_equal 1, urls.size
    assert_includes urls.first, "%E2%80%AF"
    assert_equal urls.first, @property.display_gallery_image_urls.first
  end

  test "enhanced_or_cdn skips non-configured service blobs and falls back to CDN" do
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_or_cdn"
    configured = Rails.configuration.active_storage.service.to_s
    other = configured == "local" ? "google" : "local"

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("local-bytes"),
      filename: "DJI_0088.jpg",
      content_type: "image/jpeg",
      metadata: { "source_url" => @cdn_a, "source_urls" => [ @cdn_a ], "enhanced" => true }
    )
    blob.update_columns(service_name: other)
    @property.gallery_images_attachments.create!(blob_id: blob.id)

    assert_equal [ @cdn_a, @cdn_b ], @property.reload.display_gallery_image_urls
    assert_equal @cdn_a, @property.display_image_url
    assert_empty @property.enhanced_gallery_images
  end
end
