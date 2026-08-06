require "test_helper"

class BokListingsImporterTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(
      name: "Import Agent",
      title: "Listing Feed",
      email: "importer-test@example.com",
      phone: "",
      bio: "test",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "skips creating listings with empty image arrays" do
    path = write_feed([ belmont_classic_row ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 0, result.created
    assert_equal 1, result.skipped
    assert_equal 0, result.removed
    assert_includes result.errors.join, "no usable images"
    assert_nil Property.find_by(bok_id: "BOK-1050440")
  end

  test "skips creating listings that only have theme placeholder images" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-PLACEHOLDER",
        "url" => "https://mybunchofkeys.com/property/placeholder-only/",
        "image" => "https://mybunchofkeys.com/wp-content/themes/bok/images/default.jpg",
        "images" => [ "https://mybunchofkeys.com/wp-content/themes/bok/images/default.jpg" ]
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 0, result.created
    assert_equal 1, result.skipped
    assert_nil Property.find_by(bok_id: "BOK-PLACEHOLDER")
  end

  test "creates listings with a usable gallery" do
    path = write_feed([ good_row ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    property = Property.find_by!(bok_id: "BOK-GOOD")
    assert_equal "active", property.status
    assert_equal "House", property.property_type
    assert_equal "sale", property.tag
    assert property.image_urls.any?
    assert property.image_url.present?
  end

  test "maps apartment for rent from BOK style and price" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-APT-RENT",
        "url" => "https://mybunchofkeys.com/property/cozy-apartment-for-rent/",
        "title" => "Cozy Apartment for Rent - My Bunch of Keys",
        "price" => "$4,500 / Mth",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Rent"
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    property = Property.find_by!(bok_id: "BOK-APT-RENT")
    assert_equal "Apartment", property.property_type
    assert_equal "rent", property.tag
  end

  test "maps land and commercial styles" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-LAND",
        "url" => "https://mybunchofkeys.com/property/land-for-sale-arima/",
        "title" => "Land for Sale Arima - My Bunch of Keys",
        "property_style" => "Land",
        "property_type" => "For Sale"
      ),
      good_row.merge(
        "bok_id" => "BOK-COMM",
        "url" => "https://mybunchofkeys.com/property/warehouse-space-longdenville/",
        "title" => "Warehouse Space - My Bunch of Keys",
        "property_style" => "Commercial",
        "property_type" => "For Rent",
        "price" => "$8,000 / Mth"
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 2, result.created
    land = Property.find_by!(bok_id: "BOK-LAND")
    commercial = Property.find_by!(bok_id: "BOK-COMM")
    assert_equal "Land", land.property_type
    assert_equal "sale", land.tag
    assert_equal "Commercial", commercial.property_type
    assert_equal "rent", commercial.tag
  end

  test "destroys an existing public listing when re-import has no usable images" do
    existing = Property.create!(
      agent: @agent,
      bok_id: "BOK-1050440",
      source_url: "https://mybunchofkeys.com/property/belmont-classic-on-large-lot/",
      title: "Belmont Classic on large lot",
      slug: "belmont-classic-on-large-lot",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Industry Lane",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 79_500_000,
      description: "Classic house",
      image_url: "https://mybunchofkeys.com/wp-content/uploads/2020/01/broken-404.jpg",
      image_urls: [ "https://mybunchofkeys.com/wp-content/uploads/2020/01/broken-404.jpg" ],
      latitude: 10.6620,
      longitude: -61.5050
    )

    path = write_feed([ belmont_classic_row ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.removed
    assert_equal 0, result.updated
    assert_includes result.errors.join, "removed"
    assert_nil Property.find_by(id: existing.id)
  end

  private

  def write_feed(rows)
    path = Rails.root.join("tmp/bok_importer_test_#{SecureRandom.hex(4)}.json")
    File.write(path, JSON.pretty_generate(rows))
    path
  end

  def belmont_classic_row
    {
      "url" => "https://mybunchofkeys.com/property/belmont-classic-on-large-lot/",
      "title" => "Belmont Classic on large lot - My Bunch of Keys",
      "price" => "$795,000",
      "bok_id" => "BOK-1050440",
      "location" => "Industry Lane, Belmont, Belmont",
      "bedrooms" => "4",
      "bathrooms" => "2",
      "sqft" => "4484sq.ft.",
      "image" => "",
      "images" => [],
      "description" => "Industry Lane classic house on a generous lot.",
      "features" => [ "Freehold Land" ]
    }
  end

  def good_row
    {
      "url" => "https://mybunchofkeys.com/property/archer-street-belmont/",
      "title" => "Archer Street Belmont Home - My Bunch of Keys",
      "price" => "$1,200,000",
      "bok_id" => "BOK-GOOD",
      "location" => "Archer Street, Belmont",
      "bedrooms" => "3",
      "bathrooms" => "2",
      "sqft" => "2000sq.ft.",
      "property_style" => "House",
      "property_type" => "For Sale",
      "image" => "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-1.jpg",
      "images" => [
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-1.jpg",
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-2.jpg"
      ],
      "description" => "Solid Belmont home with gallery photos.",
      "features" => [ "Gated Compound" ]
    }
  end
end
