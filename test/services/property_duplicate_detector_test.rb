require "test_helper"

class PropertyDuplicateDetectorTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Dup Agent",
      title: "Agent",
      email: "dup-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "dry_run finds strong pairs without writing" do
    a = create_listing!(
      title: "Spacious 3 Bedroom House Westmoorings",
      slug: "dup-a-#{SecureRandom.hex(2)}",
      address: "12 Westmoorings Rd",
      city: "Westmoorings",
      price_cents: 2_500_000_00,
      features: [ "Pool", "Garage", "Security" ],
      latitude: 10.68,
      longitude: -61.56
    )
    b = create_listing!(
      title: "Spacious 3 Bedroom House in Westmoorings",
      slug: "dup-b-#{SecureRandom.hex(2)}",
      address: "12 Westmoorings Road",
      city: "Westmoorings",
      price_cents: 2_500_000_00,
      features: [ "Pool", "Garage", "Garden" ],
      latitude: 10.6801,
      longitude: -61.5601
    )
    other = create_listing!(
      title: "Totally Different Condo",
      slug: "dup-c-#{SecureRandom.hex(2)}",
      address: "99 Other St",
      city: "Arima",
      price_cents: 800_000_00,
      features: [ "Balcony" ],
      latitude: 10.63,
      longitude: -61.28
    )

    result = PropertyDuplicateDetector.call(dry_run: true)
    assert result.dry_run
    assert_operator result.pair_count, :>=, 1
    assert_includes result.flagged_ids, a.id
    assert_includes result.flagged_ids, b.id
    refute_includes result.flagged_ids, other.id
    refute a.reload.possible_duplicate
    refute b.reload.possible_duplicate
  end

  test "apply flags matching listings and clears stale flags" do
    a = create_listing!(
      title: "Corner Lot Penal",
      slug: "dup-d-#{SecureRandom.hex(2)}",
      address: "Corner Lot Penal",
      city: "Penal",
      price_cents: 450_000_00,
      features: [ "Flat", "Road Access" ],
      latitude: 10.16,
      longitude: -61.46,
      possible_duplicate: false
    )
    b = create_listing!(
      title: "Corner Lot in Penal",
      slug: "dup-e-#{SecureRandom.hex(2)}",
      address: "Corner Lot Penal",
      city: "Penal",
      price_cents: 450_000_00,
      features: [ "Flat", "Road Access", "Fenced" ],
      latitude: 10.1601,
      longitude: -61.4601
    )
    stale = create_listing!(
      title: "Unrelated Stale Flag",
      slug: "dup-f-#{SecureRandom.hex(2)}",
      address: "1 Alone St",
      city: "Tobago",
      price_cents: 100_000_00,
      features: [],
      possible_duplicate: true
    )

    result = PropertyDuplicateDetector.call(dry_run: false)
    assert result.applied
    assert a.reload.possible_duplicate
    assert b.reload.possible_duplicate
    refute stale.reload.possible_duplicate
  end

  test "signals_between compares two listings without a full scan" do
    a = create_listing!(
      title: "Spacious 3 Bedroom House Westmoorings",
      slug: "sig-a-#{SecureRandom.hex(2)}",
      address: "12 Westmoorings Rd",
      city: "Westmoorings",
      price_cents: 2_500_000_00,
      features: [ "Pool", "Garage", "Security" ],
      latitude: 10.68,
      longitude: -61.56
    )
    b = create_listing!(
      title: "Spacious 3 Bedroom House in Westmoorings",
      slug: "sig-b-#{SecureRandom.hex(2)}",
      address: "12 Westmoorings Road",
      city: "Westmoorings",
      price_cents: 2_500_000_00,
      features: [ "Pool", "Garage", "Garden" ],
      latitude: 10.6801,
      longitude: -61.5601
    )

    signals = PropertyDuplicateDetector.signals_between(a, b)
    assert_operator signals.size, :>=, 3
  end

  private

  def create_listing!(attrs)
    Property.create!(
      {
        agent: @agent,
        tag: "sale",
        property_type: "House",
        status: "active",
        state: "Trinidad",
        zip: ""
      }.merge(attrs)
    )
  end
end
