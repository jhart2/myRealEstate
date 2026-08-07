require "test_helper"

class PropertyStreetGeocoderTest < ActiveSupport::TestCase
  test "detects CITY_COORDS dumps" do
    lat, lng = BokListingsImporter::CITY_COORDS["maraval"]
    assert PropertyStreetGeocoder.city_level_coords?(lat, lng)
    assert PropertyStreetGeocoder.city_level_coords?(*BokListingsImporter::DEFAULT_COORDS)
    refute PropertyStreetGeocoder.city_level_coords?(10.69135, -61.51844)
  end

  test "street_worthy? accepts numbered streets and rejects city stubs" do
    assert PropertyStreetGeocoder.street_worthy?("12 Saddle Road", "Maraval")
    assert PropertyStreetGeocoder.street_worthy?("Daniel Drive", "Champs Fleurs")
    refute PropertyStreetGeocoder.street_worthy?("Chaguanas", "Chaguanas")
    refute PropertyStreetGeocoder.street_worthy?("House For Sale", "Maraval")
  end

  test "needs_refine? only when street parked on centroid" do
    attrs = {
      address: "12 Saddle Road",
      city: "Maraval",
      state: "Trinidad",
      latitude: BokListingsImporter::CITY_COORDS["maraval"][0],
      longitude: BokListingsImporter::CITY_COORDS["maraval"][1]
    }
    assert PropertyStreetGeocoder.needs_refine?(attrs)

    attrs[:latitude] = 10.69135
    attrs[:longitude] = -61.51844
    refute PropertyStreetGeocoder.needs_refine?(attrs)

    attrs = {
      address: "Chaguanas",
      city: "Chaguanas",
      latitude: BokListingsImporter::CITY_COORDS["chaguanas"][0],
      longitude: BokListingsImporter::CITY_COORDS["chaguanas"][1]
    }
    refute PropertyStreetGeocoder.needs_refine?(attrs)
  end

  test "refine applies google coords for street on centroid" do
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

    refined = PropertyStreetGeocoder.refine(
      {
        address: "12 Saddle Road",
        city: "Maraval",
        state: "Trinidad",
        latitude: BokListingsImporter::CITY_COORDS["maraval"][0],
        longitude: BokListingsImporter::CITY_COORDS["maraval"][1]
      },
      google: google
    )

    assert_in_delta 10.69135, refined.latitude, 0.0001
    assert_in_delta(-61.51844, refined.longitude, 0.0001)
  end

  test "refine skips approximate locality-only hits" do
    google = Object.new
    def google.configured? = true
    def google.resolve(query:, region_hint: nil)
      GoogleAddressClient::Result.new(
        formatted_address: "Champs Fleurs",
        address: "",
        city: "Champs Fleurs",
        state: "Trinidad",
        zip: nil,
        latitude: 10.65,
        longitude: -61.42,
        place_id: "x",
        location_type: "APPROXIMATE",
        confidence: 55,
        source: "geocoding",
        raw: { "types" => [ "locality" ], "_types" => [ "locality" ] }
      )
    end

    refined = PropertyStreetGeocoder.refine(
      {
        address: "Daniel Drive",
        city: "Champs Fleurs",
        state: "Trinidad",
        latitude: BokListingsImporter::CITY_COORDS["champs fleurs"][0],
        longitude: BokListingsImporter::CITY_COORDS["champs fleurs"][1]
      },
      google: google
    )

    assert_nil refined
  end
end
