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
end
