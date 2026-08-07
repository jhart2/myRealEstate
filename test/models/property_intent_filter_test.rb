require "test_helper"

class PropertyIntentFilterTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Intent Tester",
      title: "Agent",
      email: "intent-tester@example.com",
      phone: "555-0100",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    @sale = create_property!(title: "Sale Home", tag: "sale")
    @rent = create_property!(title: "Rent Home", tag: "rent")
  end

  test "intent=sale returns only sale listings" do
    ids = Property.search(intent: "sale").pluck(:id)
    assert_equal [ @sale.id ], ids
  end

  test "intent=rent returns only rent listings" do
    ids = Property.search(intent: "rent").pluck(:id)
    assert_equal [ @rent.id ], ids
  end

  test "blank or all intent returns sale and rent" do
    assert_equal [ @sale.id, @rent.id ].sort, Property.search.pluck(:id).sort
    assert_equal [ @sale.id, @rent.id ].sort, Property.search(intent: "all").pluck(:id).sort
  end

  private

  def create_property!(title:, tag:)
    Property.create!(
      title: title,
      address: "1 Test Rd",
      city: "Port of Spain",
      state: "TT",
      zip: "00000",
      price_cents: 500_000_00,
      tag: tag,
      property_type: "House",
      status: "active",
      beds: 2,
      baths: 1,
      featured: false,
      agent: @agent
    )
  end
end
