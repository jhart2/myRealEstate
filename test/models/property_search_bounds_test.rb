require "test_helper"

class PropertySearchBoundsTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Bounds Tester",
      title: "Agent",
      email: "bounds-tester@example.com",
      phone: "555-0100",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    @pos = Property.create!(
      title: "Port Home",
      address: "1 Independence Sq",
      city: "Port of Spain",
      state: "Trinidad",
      zip: "",
      price_cents: 100_000_00,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: 2,
      baths: 1,
      latitude: 10.65,
      longitude: -61.52,
      agent: @agent
    )
  end

  test "valid viewport bounds filter listings" do
    ids = Property.search(
      north: 10.66,
      south: 10.64,
      east: -61.51,
      west: -61.53
    ).pluck(:id)

    assert_equal [ @pos.id ], ids
  end

  test "degenerate uninitialized map bounds are ignored instead of emptying results" do
    # Leaflet zero-size / unsettled maps often sync north=south=east=west=0
    count = Property.search(
      north: 0,
      south: 0,
      east: 0,
      west: 0,
      intent: "sale"
    ).count

    assert_equal 1, count
  end

  test "inverted or NaN bounds are ignored instead of emptying results" do
    assert_equal 1, Property.search(
      north: 10.64,
      south: 10.66,
      east: -61.53,
      west: -61.51
    ).count

    assert_equal 1, Property.search(
      north: "NaN",
      south: "NaN",
      east: "NaN",
      west: "NaN"
    ).count
  end
end
