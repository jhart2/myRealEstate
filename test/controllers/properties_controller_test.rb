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
    get photo_download_property_path(property, 0)

    assert_response :success
    assert_equal "attachment", response.headers["Content-Disposition"].to_s[/\A([^;]+)/, 1]
    assert_includes response.headers["Content-Disposition"], "#{property.slug}-1.jpg"
    assert_operator response.body.bytesize, :>, 0
  end

  test "photo_download 404s for out-of-range index" do
    property = Property.first
    get photo_download_property_path(property, 99)
    assert_response :not_found
  end
end
