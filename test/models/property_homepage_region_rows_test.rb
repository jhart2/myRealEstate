require "test_helper"

class PropertyHomepageRegionRowsTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Homepage Tester",
      title: "Agent",
      email: "homepage-tester@example.com",
      phone: "555-0300",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )
  end

  test "homepage region rows exclude land and commercial from homes carousels" do
    house = create_property!(title: "POS House", city: "Port of Spain", property_type: "House", featured: true)
    create_property!(title: "POS Land", city: "Port of Spain", property_type: "Land", featured: true, views_count: 9_999)
    create_property!(title: "POS Commercial", city: "Port of Spain", property_type: "Commercial", featured: true, views_count: 9_998)
    apartment = create_property!(title: "POS Apt", city: "Port of Spain", property_type: "Apartment")

    rows = Property.homepage_region_rows(per_region: 12)
    north_west = rows.find { |row| row[:region].key == "north_west" }

    assert north_west, "expected a North West region row"
    ids = north_west[:properties].map(&:id)
    types = north_west[:properties].map(&:property_type).uniq.sort

    assert_includes ids, house.id
    assert_includes ids, apartment.id
    assert_equal %w[Apartment House], types
    assert_empty north_west[:properties].select { |p| Property::NON_RESIDENTIAL_TYPES.include?(p.property_type) }
  end

  test "homepage region rows omit regions that only have non-residential inventory" do
    create_property!(title: "POS Land Only", city: "Port of Spain", property_type: "Land", featured: true)

    rows = Property.homepage_region_rows(per_region: 12)
    north_west = rows.find { |row| row[:region].key == "north_west" }

    assert_nil north_west
  end

  private

  def create_property!(title:, city:, property_type:, featured: false, views_count: 0)
    Property.create!(
      title: title,
      address: "1 Test Rd",
      city: city,
      state: "TT",
      zip: "00000",
      price_cents: 500_000_00,
      tag: "sale",
      property_type: property_type,
      status: "active",
      beds: property_type == "Land" ? 0 : 2,
      baths: property_type == "Land" ? 0 : 1,
      featured: featured,
      views_count: views_count,
      agent: @agent
    )
  end
end
