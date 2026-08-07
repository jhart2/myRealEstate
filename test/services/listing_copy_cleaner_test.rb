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

    assert_equal "Fairways Family Home", result.cleaned["title"]
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
end
