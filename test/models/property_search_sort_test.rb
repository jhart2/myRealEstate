require "test_helper"

class PropertySearchSortTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Sort Tester",
      title: "Agent",
      email: "sort-tester@example.com",
      phone: "555-0100",
      sales_volume: "$1M",
      years_experience: 1,
      bio: "Test",
      active: true
    )

    @low = create_property!(title: "Low Price", price_cents: 100_000_00, featured: true)
    @mid = create_property!(title: "Mid Price", price_cents: 500_000_00, featured: false)
    @high = create_property!(title: "High Price", price_cents: 900_000_00, featured: true)
  end

  test "price_asc and price_desc order by price_cents with symbol or string keys" do
    [ { sort: "price_asc" }, { "sort" => "price_asc" } ].each do |params|
      assert_equal [ @low.id, @mid.id, @high.id ], Property.search(params).pluck(:id)
    end

    [ { sort: "price_desc" }, { "sort" => "price_desc" } ].each do |params|
      assert_equal [ @high.id, @mid.id, @low.id ], Property.search(params).pluck(:id)
    end
  end

  test "price sort works through permitted controller params" do
    permitted = ActionController::Parameters.new("sort" => "price_asc").permit(:sort)
    assert_equal [ @low.id, @mid.id, @high.id ], Property.search(permitted).pluck(:id)

    permitted = ActionController::Parameters.new(sort: "price_desc").permit(:sort)
    assert_equal [ @high.id, @mid.id, @low.id ], Property.search(permitted).pluck(:id)
  end

  private

  def create_property!(title:, price_cents:, featured:)
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
      beds: 2,
      baths: 1,
      featured: featured,
      agent: @agent
    )
  end
end
