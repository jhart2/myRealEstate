require "test_helper"

class ListingCopyCleanerTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(payload)
      @payload = payload
    end

    def chat(**)
      {
        content: JSON.generate(@payload),
        model: "fake",
        usage: { "total_tokens" => 10 },
        raw: {}
      }
    end
  end

  test "returns cleaned copy and verification from model JSON" do
    payload = {
      "cleaned" => {
        "title" => "Fairways Family Home",
        "address" => "Fairways",
        "city" => "Maraval",
        "state" => "Trinidad",
        "zip" => "",
        "description" => "A spacious six-bedroom home in Fairways, Maraval.",
        "beds" => 6,
        "baths" => 7,
        "sqft" => 6000,
        "lot_sqft" => nil,
        "acres" => nil,
        "property_type" => "House",
        "tag" => "sale",
        "features" => [ "Private Pool", "Gated Compound" ]
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 0.82,
        "mismatches" => [
          {
            "field" => "city",
            "model" => "Fairways, Maraval",
            "from_description" => "Maraval",
            "note" => "City field duplicated place names"
          }
        ],
        "notes" => [ "Title had sale language removed" ]
      }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Fairways, Maraval Home for Sale",
        address: "Fairways",
        city: "Fairways, Maraval",
        state: "Trinidad",
        description: "Well built home in Fairways, Maraval with 6 bedrooms.",
        beds: 6,
        baths: 7,
        sqft: 6000,
        property_type: "House",
        tag: "sale",
        features: [ "Private Pool" ]
      },
      client: FakeClient.new(payload)
    )

    assert_match(/Fairways/i, result.cleaned["title"])
    assert_match(/Family|Home|House|Bed/i, result.cleaned["title"])
    refute_match(/for sale|TT\$/i, result.cleaned["title"])
    assert_equal "Maraval", result.cleaned["city"]
    assert_equal "mismatch", result.status
    assert result.mismatches?
    assert_equal "city", result.verification["mismatches"].first["field"]
  end

  test "falls back to safe property_type and tag when model invents values" do
    payload = {
      "cleaned" => {
        "title" => "Coastal Lot",
        "address" => "Mayaro",
        "city" => "Mayaro",
        "state" => "Trinidad",
        "description" => "Land for sale.",
        "property_type" => "Beach Hut",
        "tag" => "lease",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.5, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Land",
        description: "Land for sale",
        property_type: "Land",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    assert_equal "Land", result.cleaned["property_type"]
    assert_equal "sale", result.cleaned["tag"]
  end

  test "reclassifies imported land-as-sqft into lot_sqft instead of wiping size" do
    payload = {
      "cleaned" => {
        "title" => "Starter Home in Cunupia",
        "address" => "Hin Kin Road",
        "city" => "Cunupia",
        "state" => "Trinidad",
        "description" => "Affordable home on 5,000 sq. ft. of freehold land.",
        "beds" => 1,
        "baths" => 1,
        "sqft" => nil,
        "lot_sqft" => 5000,
        "acres" => nil,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          {
            "field" => "sqft",
            "model" => 5000,
            "from_description" => "land 5000 / house unknown",
            "note" => "Imported sqft was land area"
          }
        ]
      }
    }

    result = ListingCopyCleaner.call(
      {
        title: "1 Bedroom Starter Home, Cunupia $925,000 Neg",
        description: "AFFORDABLE HOME + 5,000 SQ. FT. OF LAND IN CUNUPIA",
        beds: 1,
        baths: 1,
        sqft: 5000,
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    assert_nil result.cleaned["sqft"]
    assert_equal 5000, result.cleaned["lot_sqft"]
  end

  test "keeps prior sqft chip if model blanks size without mining lot_sqft" do
    payload = {
      "cleaned" => {
        "title" => "Home",
        "address" => "Main Road",
        "city" => "Arima",
        "state" => "Trinidad",
        "description" => "Nice home.",
        "beds" => 3,
        "baths" => 2,
        "sqft" => nil,
        "lot_sqft" => nil,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.5, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      { title: "Home", description: "Nice home.", sqft: 2400, property_type: "House", tag: "sale" },
      client: FakeClient.new(payload)
    )

    assert_equal 2400, result.cleaned["sqft"]
  end

  test "strips duplicated city from address line" do
    payload = {
      "cleaned" => {
        "title" => "Hin Kin Road Starter Home",
        "address" => "Hin Kin Road, Cunupia",
        "city" => "Cunupia",
        "state" => "Trinidad",
        "description" => "Home on Hin Kin Road in Cunupia.",
        "beds" => 1,
        "baths" => 1,
        "sqft" => nil,
        "lot_sqft" => 5000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "1 Bedroom Starter Home, Cunupia",
        description: "5,000 SQ. FT. OF LAND IN CUNUPIA",
        city: "Cunupia",
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    assert_equal "Hin Kin Road", result.cleaned["address"]
    assert_equal "Cunupia", result.cleaned["city"]
    refute_match(/Cunupia.*Cunupia/i, [ result.cleaned["address"], result.cleaned["city"], result.cleaned["state"] ].compact.join(", "))
  end

  test "replaces country-as-city Trinidad Trinidad with mined locality" do
    payload = {
      "cleaned" => {
        "title" => "Turn-Key Family Home in Shorelands",
        "address" => "Turn",
        "city" => "Trinidad",
        "state" => "Trinidad",
        "description" => "Family home in Shorelands in the West.",
        "beds" => 3,
        "baths" => 2,
        "sqft" => 3125,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.8, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Turn-Key Family Home in Shorelands",
        address: "Turn",
        city: "Trinidad",
        state: "Trinidad",
        description: "This home is located in Shorelands.",
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    assert_equal "Shorelands", result.cleaned["city"]
    assert_equal "Trinidad", result.cleaned["state"]
    refute_equal result.cleaned["city"].downcase, result.cleaned["state"].downcase
    full = [ result.cleaned["address"], result.cleaned["city"], result.cleaned["state"] ].compact_blank.join(", ")
    refute_match(/Trinidad,\s*Trinidad/i, full)
    refute_match(/Shorelands,\s*Shorelands/i, full)
    assert_equal "Shorelands, Trinidad", full
  end

  test "clears Property for Sale address stubs" do
    payload = {
      "cleaned" => {
        "title" => "Hillsboro, Maraval",
        "address" => "Property for Sale",
        "city" => "Maraval",
        "state" => "Trinidad",
        "description" => "House in Hillsboro, Maraval.",
        "beds" => 3,
        "baths" => 3,
        "sqft" => 8600,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Property for Sale",
        address: "Property for Sale",
        city: "Hillsboro Maraval",
        description: "FOR SALE\n\nAbout the Region\nHillsboro is a residential area.",
        beds: 3,
        baths: 3,
        sqft: 8600,
        property_type: "House",
        tag: "sale",
        features: [ "Private Pool", "Gated Compound" ]
      },
      client: FakeClient.new(payload)
    )

    assert_equal "", result.cleaned["address"]
  end

  test "collapses hallucinated amenities when source description is sparse" do
    payload = {
      "cleaned" => {
        "title" => "Hillsboro, Maraval",
        "address" => "Hillsboro",
        "city" => "Maraval",
        "state" => "Trinidad",
        "description" => "The home is semi-furnished and move-in ready, located within a gated community that includes a private pool, air conditioning, a patio, and a covered garage.",
        "beds" => 3,
        "baths" => 3,
        "sqft" => 8600,
        "lot_sqft" => 8600,
        "property_type" => "House",
        "tag" => "sale",
        "features" => [ "Private Pool", "Gated Compound", "Air Conditioning" ]
      },
      "verification" => { "status" => "ok", "confidence" => 1.0, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Property for Sale",
        address: "Hillsboro Maraval",
        city: "Maraval",
        description: "FOR SALE\n\nAbout the Region\nHillsboro Hillsboro is a residential area located in Maraval Trinidad.",
        beds: 3,
        baths: 3,
        sqft: 8600,
        lot_sqft: 8600,
        property_type: "House",
        tag: "sale",
        features: [ "Private Pool", "Gated Compound", "Air Conditioning" ]
      },
      client: FakeClient.new(payload)
    )

    assert_equal "needs_review", result.status
    assert_empty result.cleaned["features"]
    desc = result.cleaned["description"].downcase
    refute_match(/\bpool\b/, desc)
    refute_match(/\bgated\b/, desc)
    refute_match(/air conditioning/, desc)
    assert_match(/3 bedroom/, desc)
    assert_match(/maraval/i, desc)
  end

  test "drops feature chips that are not grounded in title or description" do
    payload = {
      "cleaned" => {
        "title" => "Family Home in Maraval",
        "address" => "Saddle Road",
        "city" => "Maraval",
        "state" => "Trinidad",
        "description" => "A 4 bedroom house on Saddle Road in Maraval with a large yard.",
        "beds" => 4,
        "baths" => 3,
        "sqft" => 3000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => [ "Private Pool", "Yard", "Large Yard" ]
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Family Home in Maraval",
        description: "A 4 bedroom house on Saddle Road in Maraval with a large yard.",
        beds: 4,
        baths: 3,
        sqft: 3000,
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    refute_includes result.cleaned["features"], "Private Pool"
    assert(result.cleaned["features"].any? { |f| f.match?(/yard/i) })
  end

  test "strips marketing title fragments from address and mines a real street" do
    payload = {
      "cleaned" => {
        "title" => "Charming 3-Bedroom Home in Westmoorings",
        "address" => "Charming 3",
        "city" => "Westmoorings",
        "state" => "Trinidad",
        "description" => "Upgraded 3 bedroom home in Westmoorings.",
        "beds" => 3,
        "baths" => 3,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Charming 3-Bedroom Home – For Sale or Rent!",
        address: "Charming 3",
        city: "Westmoorings",
        description: "Nestled in Westmoorings, this upgraded 3-bedroom home is move-in ready.",
        beds: 3,
        baths: 3,
        property_type: "House",
        tag: "sale",
        source_url: "https://mybunchofkeys.com/property/newly-renovated-single-storey-executive-home-for-sale-in-north-west-moorings/"
      },
      client: FakeClient.new(payload)
    )

    refute_match(/charming|bed|sale/i, result.cleaned["address"])
    assert_equal "Westmoorings", result.cleaned["city"]
  end

  test "rejects 3 Bed House Orange Grove style address fragments" do
    payload = {
      "cleaned" => {
        "title" => "Renovated 3-Bed House in Orange Grove, Tacarigua",
        "address" => "3 Bed House Orange Grove",
        "city" => "Tacarigua",
        "state" => "Trinidad",
        "description" => "A 3 bedroom house in Orange Grove, Tacarigua.",
        "beds" => 3,
        "baths" => 2,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "3 Bed House Orange Grove, Tacarigua For Sale",
        address: "3 Bed House Orange Grove",
        city: "Tacarigua",
        description: "3 bedroom house located in Orange Grove, Tacarigua.",
        beds: 3,
        baths: 2,
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    refute_match(/\bbed\b|house/i, result.cleaned["address"])
    addr = result.cleaned["address"]
    assert(addr.blank? || addr.match?(/orange\s+grove/i))
  end

  test "rewrites place-only titles into grounded SEO titles" do
    payload = {
      "cleaned" => {
        "title" => "Cleaver Heights, Arima",
        "address" => "Cleaver Heights",
        "city" => "Arima",
        "state" => "Trinidad",
        "description" => "Grand 4 bedroom home needing some TLC on freehold land.",
        "beds" => 4,
        "baths" => 3,
        "sqft" => 3235,
        "lot_sqft" => 10381,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.9, "mismatches" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "Cleaver Heights, Arima - Home for Sale- TT$2M",
        description: "For Sale: Arima Home. While the home may require some TLC. 4 Bedrooms. Land Size: 10,381 Square Feet Building Size: 3,235 Square Feet",
        beds: 4,
        baths: 3,
        sqft: 10381,
        property_type: "House",
        tag: "sale",
        address: "Cleaver Heights",
        city: "Arima"
      },
      client: FakeClient.new(payload)
    )

    title = result.cleaned["title"]
    refute_equal "Cleaver Heights, Arima", title
    assert_operator title.length, :>=, 36
    assert_match(/Arima/i, title)
    assert_match(/TLC|4-Bed|Family|Home|House/i, title)
    refute_match(/TT\$|for sale/i, title)
  end
end
