require "test_helper"

class OverpassStreetFinderTest < ActiveSupport::TestCase
  test "normalizes and scores an exact highway hit inside bbox" do
    finder = OverpassStreetFinder.new
    def finder.query_overpass(_street, _bbox)
      [
        { name: "Daniel Drive", lat: 10.6501, lng: -61.4188, osm_id: 1, highway: "residential" },
        { name: "1st Drive", lat: 10.6510, lng: -61.4300, osm_id: 2, highway: "residential" }
      ]
    end
    def finder.bbox_for(city:, state: nil)
      [ -61.45, 10.62, -61.40, 10.67 ]
    end

    hit = finder.find(name: "12 Daniel Drive", city: "Champs Fleurs")
    assert_equal "Daniel Drive", hit.name
    assert_in_delta 10.6501, hit.latitude, 0.00001
    assert_equal "overpass", hit.source
  end
end

class AddressQueryForgeTest < ActiveSupport::TestCase
  test "heuristic variants cover Champ Fleurs spelling" do
    openai = Object.new
    def openai.configured? = false
    forge = AddressQueryForge.new(openai: openai)
    result = forge.call(address: "Daniel Drive", city: "Champs Fleurs", state: "Trinidad")
    assert result[:queries].any? { |q| q.include?("Champ Fleurs") }
    assert result[:queries].any? { |q| q.include?("Trinidad and Tobago") }
  end
end
