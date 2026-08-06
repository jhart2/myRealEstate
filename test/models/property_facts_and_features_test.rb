require "test_helper"

class PropertyFactsAndFeaturesTest < ActiveSupport::TestCase
  test "groups structured attrs and known BOK amenities" do
    property = Property.new(
      beds: 4,
      baths: 3,
      sqft: 2500,
      property_type: "House",
      acres: 1,
      features: [
        "Air Conditioning",
        "Kitchen Island",
        "Patio",
        "Covered Garage",
        "Freehold Land",
        "Water Tank",
        "Custom Odd Feature"
      ]
    )

    groups = property.facts_and_features_groups
    by_name = groups.index_by { |g| g[:name] }

    interior = by_name.fetch("Interior")[:categories].index_by { |c| c[:name] }
    assert_equal [ "Bedrooms: 4", "Bathrooms: 3" ], interior.fetch("Bedrooms & bathrooms")[:items]
    assert_equal [ "Kitchen Island" ], interior.fetch("Kitchen")[:items]
    assert_equal [ "Air Conditioning" ], interior.fetch("Heating & cooling")[:items]

    exterior = by_name.fetch("Exterior")[:categories].index_by { |c| c[:name] }
    assert_includes exterior.fetch("Lot")[:items], "Building size: 2,500 sqft"
    assert_includes exterior.fetch("Lot")[:items], "Lot size: 1 Acre"
    assert_includes exterior.fetch("Lot")[:items], "Type: House"
    assert_includes exterior.fetch("Lot")[:items], "Freehold Land"
    assert_equal [ "Covered Garage" ], exterior.fetch("Parking")[:items]
    assert_equal [ "Patio" ], exterior.fetch("Outdoor living")[:items]

    other = by_name.fetch("Other")[:categories].index_by { |c| c[:name] }
    assert_equal [ "Water Tank" ], other.fetch("Utilities")[:items]
    assert_equal [ "Custom Odd Feature" ], other.fetch("Features")[:items]
  end

  test "omits empty categories and groups" do
    property = Property.new(beds: 2, baths: nil, property_type: "Villa", features: [ "Patio" ])
    groups = property.facts_and_features_groups

    assert_equal [ "Interior", "Exterior" ], groups.map { |g| g[:name] }
    assert_nil groups.find { |g| g[:name] == "Other" }
    assert_equal [ "Bedrooms & bathrooms" ], groups[0][:categories].map { |c| c[:name] }
    refute groups.flat_map { |g| g[:categories] }.any? { |c| c[:items].empty? }
  end
end
