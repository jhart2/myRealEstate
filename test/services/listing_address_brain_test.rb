require "test_helper"

class ListingAddressBrainTest < ActiveSupport::TestCase
  test "heuristic path stays cheap when document is strong" do
    row = {
      "title" => "Renovated Commercial in #8 Pokhor Road, Longdenville",
      "location" => "Longdenville",
      "url" => "https://mybunchofkeys.com/property/pokhor-road/",
      "description" => "#8 Pokhor Road, Longdenville commercial space",
      "weak_address" => false
    }

    result = ListingAddressBrain.enrich(row)

    assert_match(/heuristic/, result.source)
    assert_equal false, result.weak
    assert_match(/Pokhor/i, result.address)
  end

  test "strong street on city centroid still gets street geocode when google is available" do
    google = Object.new
    def google.configured? = true
    def google.resolve(query:, region_hint: nil)
      GoogleAddressClient::Result.new(
        formatted_address: "12 Saddle Road, Maraval",
        address: "12 Saddle Road",
        city: "Maraval",
        state: "Trinidad",
        zip: nil,
        latitude: 10.69135,
        longitude: -61.51844,
        place_id: "x",
        location_type: "RANGE_INTERPOLATED",
        confidence: 85,
        source: "geocoding",
        raw: { "types" => [ "street_address" ], "_types" => [ "street_address" ] }
      )
    end

    openai = Object.new
    def openai.configured? = false

    row = {
      "title" => "12 Saddle Road, Maraval",
      "location" => "Maraval",
      "url" => "https://mybunchofkeys.com/property/12-saddle-road/",
      "description" => "Family home on 12 Saddle Road, Maraval"
    }

    result = ListingAddressBrain.new(openai: openai, google: google).enrich(row)

    assert_match(/Saddle/i, result.address)
    assert_in_delta 10.69135, result.latitude, 0.0001
    assert_match(/street_geocode|google/, result.source)
  end

  test "weak_document? respects scraper weak_address flag" do
    row = {
      "title" => "Mystery listing",
      "location" => "Maraval",
      "description" => "Nice home",
      "weak_address" => true,
      "weak_reasons" => [ "no_street_signal" ]
    }

    assert ListingAddressBrain.weak_document?(row)
  end
end
