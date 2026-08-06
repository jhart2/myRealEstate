require "test_helper"

class PropertyPriceHistogramTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Histogram Tester",
      title: "Agent",
      email: "histogram-tester@example.com",
      phone: "555-0101",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    create_property!(title: "Budget Cottage", price_cents: 200_000_00, beds: 2)
    create_property!(title: "Mid Villa", price_cents: 900_000_00, beds: 3)
    create_property!(title: "Estate", price_cents: 4_500_000_00, beds: 5)
    create_property!(title: "Mega Estate", price_cents: 12_000_000_00, beds: 6)
  end

  test "price_histogram returns fixed bucket counts from active listings" do
    counts = Property.price_histogram({}, buckets: 40, max_dollars: 10_000_000)

    assert_equal 40, counts.length
    assert_equal 4, counts.sum
    assert counts.any?(&:positive?)
    # $12M+ lands in the final overflow bucket
    assert_operator counts.last, :>=, 1
  end

  test "price_histogram ignores current price filters but respects other filters" do
    with_price = Property.price_histogram({ price_min: 8_000_000, price_max: 9_000_000 }, buckets: 20)
    without_price = Property.price_histogram({}, buckets: 20)
    assert_equal without_price, with_price

    beds_only = Property.price_histogram({ beds: 5 }, buckets: 20)
    assert_equal 2, beds_only.sum
  end

  private

  def create_property!(title:, price_cents:, beds:)
    Property.create!(
      title: title,
      address: "1 Test Rd",
      city: "Port of Spain",
      state: "TT",
      zip: "00000",
      price_cents: price_cents,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: beds,
      baths: 1,
      agent: @agent
    )
  end
end
