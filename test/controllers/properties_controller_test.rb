require "test_helper"
require "stringio"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @prev_mode = ENV["GALLERY_DISPLAY_MODE"]
    ENV["GALLERY_DISPLAY_MODE"] = "enhanced_or_cdn"
    Agent.delete_all
    Property.delete_all

    @agent = Agent.create!(
      name: "Index Agent",
      title: "Agent",
      email: "index-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )

    12.times do |i|
      cdn = "https://cdn.example.com/home-#{i}.jpg"
      property = Property.create!(
        agent: @agent,
        title: "Index Home #{i}",
        slug: "index-home-#{i}-#{SecureRandom.hex(2)}",
        tag: "sale",
        property_type: "House",
        status: "active",
        address: "#{i} Test St",
        city: "Port of Spain",
        state: "Trinidad",
        zip: "",
        price_cents: (100_000 + i) * 100,
        latitude: 10.66 + (i * 0.001),
        longitude: -61.51 - (i * 0.001),
        image_url: cdn,
        image_urls: [ cdn, "#{cdn}?2" ]
      )
      3.times do |j|
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new("bytes-#{i}-#{j}"),
          filename: "g-#{i}-#{j}.jpg",
          content_type: "image/jpeg",
          metadata: {
            "source_url" => cdn,
            "source_urls" => [ cdn ],
            "enhanced" => true
          }
        )
        property.gallery_images_attachments.create!(blob_id: blob.id)
      end
    end
  end

  teardown do
    if @prev_mode.nil?
      ENV.delete("GALLERY_DISPLAY_MODE")
    else
      ENV["GALLERY_DISPLAY_MODE"] = @prev_mode
    end
  end

  test "index stays well under Active Storage query storm" do
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] !~ /SCHEMA|TRANSACTION/i }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      get properties_path
    end

    assert_response :success
    attachment_queries = queries.count { |sql| sql.match?(/active_storage_attachments|active_storage_blobs/i) }
    assert attachment_queries <= 2,
           "expected ≤2 Active Storage queries on index, got #{attachment_queries}:\n#{queries.grep(/active_storage/i).join("\n")}"
    assert queries.size < 40,
           "expected few total queries on index, got #{queries.size}"
  end

  test "photo_download sends attachment with clean slug-index filename" do
    property = Property.first
    attach_valid_jpeg!(property)

    get photo_download_property_path(property, 0)

    assert_response :success
    assert_equal "attachment", response.headers["Content-Disposition"].to_s[/\A([^;]+)/, 1]
    assert_includes response.headers["Content-Disposition"], "#{property.slug}-1.jpg"
    assert_operator response.body.bytesize, :>, 0
    assert_match %r{\Aimage/jpeg}, response.media_type.to_s
  end

  test "photo_download burns watermark into the jpeg payload" do
    property = Property.first
    attach_valid_jpeg!(property)
    original = property.hosted_gallery_images.first.blob.download

    get photo_download_property_path(property, 0)
    assert_response :success

    # Watermarked bytes should differ from the source blob.
    refute_equal original, response.body
    assert_operator response.body.bytesize, :>, 0
  end

  test "photo_download 404s for out-of-range index" do
    property = Property.first
    get photo_download_property_path(property, 99)
    assert_response :not_found
  end

  test "index shows total result count and pages the list" do
    get properties_path
    assert_response :success
    assert_match(/12 results/, response.body)
    assert_select "[data-search-map-target='resultsList']"
  end

  test "results returns paginated html and accurate total" do
    40.times do |i|
      Property.create!(
        agent: @agent,
        title: "Extra Home #{i}",
        slug: "extra-home-#{i}-#{SecureRandom.hex(2)}",
        tag: "sale",
        property_type: "House",
        status: "active",
        address: "#{i} Extra St",
        city: "San Fernando",
        state: "Trinidad",
        zip: "",
        price_cents: 200_000_00 + i,
        latitude: 10.28 + (i * 0.001),
        longitude: -61.46 - (i * 0.001),
        image_url: "https://cdn.example.com/extra-#{i}.jpg",
        image_urls: [ "https://cdn.example.com/extra-#{i}.jpg" ]
      )
    end

    get results_properties_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 52, body["totalCount"]
    assert_equal 1, body["page"]
    assert_equal 2, body["totalPages"]
    assert_equal true, body["hasMore"]
    assert_includes body["html"], "listing-"

    get results_properties_path(page: 2), as: :json
    page2 = JSON.parse(response.body)
    assert_equal 2, page2["page"]
    assert_equal false, page2["hasMore"]
  end

  test "map_markers returns listings inside viewport bounds" do
    get map_markers_properties_path(
      north: 10.665,
      south: 10.659,
      east: -61.505,
      west: -61.515
    ), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any?
    body.each do |listing|
      assert listing["lat"] <= 10.665
      assert listing["lat"] >= 10.659
      assert listing["lng"] <= -61.505
      assert listing["lng"] >= -61.515
    end
  end

  test "index does not embed map marker JSON payload" do
    get properties_path
    assert_response :success
    assert_includes response.body, 'data-search-map-listings-value="[]"'
    refute_match(/"lat"\s*:\s*10\./, response.body)
  end

  test "price_histogram returns bucket counts without price filter bias" do
    get price_histogram_properties_path(price_min: 8_000_000, beds: 99), as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal Property::PRICE_HISTOGRAM_BUCKETS, body["bucketCount"]
    assert_equal Property::PRICE_HISTOGRAM_MAX_DOLLARS, body["maxDollars"]
    assert_equal Property::PRICE_HISTOGRAM_BUCKETS, body["buckets"].length

    # beds=99 matches nothing → all zeros even though price_min was ignored
    assert_equal Array.new(Property::PRICE_HISTOGRAM_BUCKETS, 0), body["buckets"]

    get price_histogram_properties_path, as: :json
    open_market = JSON.parse(response.body)["buckets"]
    assert_operator open_market.sum, :>, 0
  end

  test "results ignores degenerate map bounds so filters stay intact" do
    get results_properties_path(north: 0, south: 0, east: 0, west: 0, intent: "sale"), as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_operator body["totalCount"], :>, 0
  end

  private

  def attach_valid_jpeg!(property)
    require "vips"
    jpeg = Vips::Image.black(320, 240, bands: 3).copy(interpretation: :srgb).jpegsave_buffer(Q: 85)
    property.gallery_images.purge
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(jpeg),
      filename: "photo.jpg",
      content_type: "image/jpeg",
      metadata: {
        "source_url" => "https://cdn.example.com/photo.jpg",
        "source_urls" => [ "https://cdn.example.com/photo.jpg" ],
        "enhanced" => true
      }
    )
    property.gallery_images_attachments.create!(blob_id: blob.id)
    property.reload
  end
end
