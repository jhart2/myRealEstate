require "test_helper"

class HashtagTagExtractorTest < ActiveSupport::TestCase
  setup do
    PropertyTag.delete_all if defined?(PropertyTag) && ActiveRecord::Base.connection.data_source_exists?("property_tags")
    Tag.delete_all if defined?(Tag) && ActiveRecord::Base.connection.data_source_exists?("tags")
    Property.delete_all
    Agent.delete_all
    @agent = Agent.create!(
      name: "Tag Agent",
      title: "Agent",
      email: "tag-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "extracts marketing hashtags and skips numeric units" do
    property = Property.create!(
      agent: @agent,
      title: "Home #1 in Port of Spain #TrinidadRealEstate #ForSale",
      slug: "home-tag-extract-#{SecureRandom.hex(2)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "1 Test St",
      city: "Port of Spain",
      state: "Trinidad",
      zip: "",
      price_cents: 100_000_00,
      features: [ "Pool", "#MoveInReady" ]
    )
    property.update!(description: "Beautiful home #DreamHome near the Savannah.")

    tags = HashtagTagExtractor.extract(property)
    slugs = tags.map { |t| t[:slug] }

    assert_includes slugs, "trinidadrealestate"
    assert_includes slugs, "forsale"
    assert_includes slugs, "moveinready"
    assert_includes slugs, "dreamhome"
    refute_includes slugs, "1"
  end
end

class PropertyHashtagTaggerTest < ActiveSupport::TestCase
  setup do
    PropertyTag.delete_all if defined?(PropertyTag) && ActiveRecord::Base.connection.data_source_exists?("property_tags")
    Tag.delete_all if defined?(Tag) && ActiveRecord::Base.connection.data_source_exists?("tags")
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Tagger Agent",
      title: "Agent",
      email: "tagger-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "creates tags and joins from listing hashtags" do
    property = Property.create!(
      agent: @agent,
      title: "Villa #TrinidadRealEstate",
      slug: "villa-tagger-#{SecureRandom.hex(2)}",
      tag: "sale",
      property_type: "Villa",
      status: "active",
      address: "2 Test St",
      city: "San Fernando",
      state: "Trinidad",
      zip: "",
      price_cents: 200_000_00
    )
    property.update!(description: "Luxury #DreamHome #TrinidadRealEstate")

    result = PropertyHashtagTagger.call(property)
    assert_equal 2, result[:tags]
    assert_equal 2, Tag.count
    assert_equal 2, property.marketing_tags.count
    assert_includes property.marketing_tags.pluck(:slug), "trinidadrealestate"
    assert_equal 1, Tag.find_by!(slug: "trinidadrealestate").listings_count
    assert_equal 1, Tag.find_by!(slug: "dreamhome").listings_count
  end
end
