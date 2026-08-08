require "test_helper"

class DuplicateDismissalTest < ActiveSupport::TestCase
  setup do
    DuplicateDismissal.delete_all
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Dismiss Agent",
      title: "Agent",
      email: "dismiss-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "stores pair with sorted ids and is idempotent" do
    low = create_listing!(slug: "low-#{SecureRandom.hex(2)}")
    high = create_listing!(slug: "high-#{SecureRandom.hex(2)}")
    # Force high.id > low.id by creation order

    first = DuplicateDismissal.dismiss!(high.id, low.id, action: "keep_both")
    second = DuplicateDismissal.dismiss!(low.id, high.id, action: "clear_left")

    assert_equal first.id, second.id
    assert_equal [ low.id, high.id ].minmax, [ first.property_low_id, first.property_high_id ]
    assert_equal "clear_left", second.action
    assert DuplicateDismissal.dismissed?(high.id, low.id)
  end

  private

  def create_listing!(slug:)
    Property.create!(
      agent: @agent,
      title: "Listing #{slug}",
      slug: slug,
      description: "t",
      price_cents: 100_000_00,
      address: "1 St",
      city: "Port of Spain",
      state: "Trinidad",
      tag: "sale",
      property_type: "House",
      status: "active",
      zip: ""
    )
  end
end
