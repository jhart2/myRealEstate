require "test_helper"

class PropertyCoordReconcilerTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(
      name: "Coord Test Agent",
      title: "Agent",
      email: "coord-test-#{SecureRandom.hex(4)}@example.com",
      active: true
    )
  end

  test "candidate? is true for Port of Spain default dump even without street" do
    lat, lng = BokListingsImporter::DEFAULT_COORDS
    property = Property.new(
      address: "Cunupia",
      city: "Cunupia",
      state: "Trinidad",
      latitude: lat,
      longitude: lng,
      location_raw: "Charlieville Chin Chin Cunupia"
    )
    assert PropertyCoordReconciler.new.candidate?(property)
  end

  test "location-led photon query can escape POS default" do
    photon = Object.new
    def photon.search(query, limit: 8)
      if query.to_s.match?(/chin chin road/i)
        [ { name: "Chin Chin Road", label: "Chin Chin Road, Chaguanas", type: "street",
            city: "Chaguanas", lat: 10.5535061, lng: -61.3706102, in_tt: true } ]
      else
        []
      end
    end

    nominatim = Object.new
    def nominatim.search(*) = []
    def nominatim.pick_best(*) = nil

    google = Object.new
    def google.configured? = false

    lat, lng = BokListingsImporter::DEFAULT_COORDS
    property = Property.create!(
      title: "Rahamut Gardens Home",
      slug: "coord-location-led-#{SecureRandom.hex(4)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Rahamut Gardens",
      city: "Cunupia",
      state: "Trinidad",
      location_raw: "Charlieville Chin Chin Cunupia",
      price_cents: 2_400_000_00,
      agent: @agent,
      latitude: lat,
      longitude: lng,
      bok_id: "BOK-LOC-#{SecureRandom.hex(3)}"
    )

    reconciler = PropertyCoordReconciler.new(photon: photon, nominatim: nominatim, google: google)
    proposals = reconciler.call(Property.where(id: property.id), limit: 1, apply: true, sources: :public)
    assert_equal "applied", proposals.first.action
    assert_in_delta 10.5535061, proposals.first.after[:latitude], 0.00001
    property.reload
    assert_in_delta 10.5535061, property.latitude.to_f, 0.00001
  end

  test "candidate? is true for street parked on city centroid" do
    lat, lng = BokListingsImporter::CITY_COORDS["champs fleurs"]
    property = Property.new(
      address: "Daniel Drive",
      city: "Champs Fleurs",
      state: "Trinidad",
      latitude: lat,
      longitude: lng
    )
    assert PropertyCoordReconciler.new.candidate?(property)
  end

  test "candidate? is true when coords missing" do
    property = Property.new(
      address: "Somewhere",
      city: "Arima",
      state: "Trinidad",
      latitude: nil,
      longitude: nil
    )
    assert PropertyCoordReconciler.new.candidate?(property)
  end

  test "public photon hit preferred over unresolved" do
    photon = Object.new
    def photon.search(_query, limit: 8)
      [ { name: "Daniel Drive", label: "Daniel Drive, Champs Fleurs", type: "street",
          lat: 10.65012, lng: -61.41888, in_tt: true } ]
    end

    nominatim = Object.new
    def nominatim.search(*) = []
    def nominatim.pick_best(*) = nil

    google = Object.new
    def google.configured? = false

    lat, lng = BokListingsImporter::CITY_COORDS["champs fleurs"]
    property = Property.create!(
      title: "Daniel Drive Home",
      slug: "coord-reconcile-#{SecureRandom.hex(4)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Daniel Drive",
      city: "Champs Fleurs",
      state: "Trinidad",
      price_cents: 1_000_000_00,
      agent: @agent,
      latitude: lat,
      longitude: lng,
      bok_id: "BOK-TEST-#{SecureRandom.hex(3)}"
    )

    reconciler = PropertyCoordReconciler.new(photon: photon, nominatim: nominatim, google: google)
    proposals = reconciler.call(Property.where(id: property.id), limit: 1, apply: false, sources: :public)
    assert_equal 1, proposals.size
    assert_equal "proposed", proposals.first.action
    assert_equal "photon", proposals.first.source
    assert_in_delta 10.65012, proposals.first.after[:latitude], 0.00001
  end
end
