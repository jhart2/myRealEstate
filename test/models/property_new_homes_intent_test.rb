require "test_helper"

class PropertyNewHomesIntentTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "New Homes Tester",
      title: "Agent",
      email: "new-homes-tester@example.com",
      phone: "555-0199",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    @fresh = create_property!(title: "Fresh Listing", created_at: 2.days.ago, tag: "sale")
    @older = create_property!(title: "Older Listing", created_at: 20.days.ago, tag: "sale")
    @rent_fresh = create_property!(title: "Fresh Rent", created_at: 1.day.ago, tag: "rent")
    @construction = create_property!(title: "Tagged New Build", created_at: 40.days.ago, tag: "new")
  end

  test "intent=new returns recently created listings across sale and rent" do
    ids = Property.search(intent: "new").pluck(:id)
    assert_includes ids, @fresh.id
    assert_includes ids, @rent_fresh.id
    assert_not_includes ids, @older.id
    assert_not_includes ids, @construction.id
  end

  test "intent=new defaults to newest sort" do
    assert_equal [ @rent_fresh.id, @fresh.id ], Property.search(intent: "new").pluck(:id)
  end

  test "intent=new respects narrower days_max" do
    ids = Property.search(intent: "new", days_max: "1").pluck(:id)
    assert_includes ids, @rent_fresh.id
    assert_not_includes ids, @fresh.id
  end

  test "new_homes scope matches 14-day window" do
    ids = Property.new_homes.pluck(:id)
    assert_includes ids, @fresh.id
    assert_not_includes ids, @older.id
  end

  private

  def create_property!(title:, created_at:, tag:)
    property = Property.create!(
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
    property.update_columns(created_at: created_at, updated_at: created_at)
    property
  end
end
