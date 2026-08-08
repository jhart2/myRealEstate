require "test_helper"

class PropertyPossibleDuplicateSearchTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(
      name: "Search Agent",
      title: "Agent",
      email: "search-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "search excludes possible duplicates" do
    visible = create_listing!(possible_duplicate: false, slug: "visible-dup-search")
    flagged = create_listing!(possible_duplicate: true, slug: "flagged-dup-search")

    ids = Property.search.pluck(:id)
    assert_includes ids, visible.id
    refute_includes ids, flagged.id
  end

  private

  def create_listing!(possible_duplicate:, slug:)
    Property.create!(
      title: "Listing #{slug}",
      slug: slug,
      description: "A nice home",
      price_cents: 500_000_00,
      address: "1 Test Rd",
      city: "Port of Spain",
      state: "Trinidad",
      beds: 3,
      baths: 2,
      property_type: "House",
      tag: "sale",
      status: "active",
      agent: @agent,
      possible_duplicate: possible_duplicate
    )
  end
end
