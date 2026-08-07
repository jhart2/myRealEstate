require "test_helper"

class PropertySearchRegionTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Region Tester",
      title: "Agent",
      email: "region-tester@example.com",
      phone: "555-0200",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    @central = create_property!(title: "Central Home", city: "Chaguanas")
    @north_west = create_property!(title: "North West Home", city: "Port of Spain")
    @south_west = create_property!(title: "South West Home", city: "San Fernando")
  end

  test "search filters by region slug" do
    ids = Property.search(region: "central").pluck(:id)
    assert_equal [ @central.id ], ids
  end

  test "search filters by region key" do
    ids = Property.search(region: "north_west").pluck(:id)
    assert_equal [ @north_west.id ], ids
  end

  test "region filter works through permitted controller params" do
    permitted = ActionController::Parameters
      .new("region" => "south-west")
      .permit(:region)

    ids = Property.search(permitted).pluck(:id)
    assert_equal [ @south_west.id ], ids
  end

  test "unknown region is ignored and returns all active listings" do
    ids = Property.search(region: "not-a-region").pluck(:id).sort
    assert_equal [ @central.id, @north_west.id, @south_west.id ].sort, ids
  end

  private

  def create_property!(title:, city:)
    Property.create!(
      title: title,
      address: "1 Test Rd",
      city: city,
      state: "TT",
      zip: "00000",
      price_cents: 500_000_00,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: 2,
      baths: 1,
      featured: false,
      agent: @agent
    )
  end
end
