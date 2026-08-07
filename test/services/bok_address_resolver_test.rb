require "test_helper"

class BokAddressResolverTest < ActiveSupport::TestCase
  test "strips N/A and uses title city when location is placeholder" do
    result = BokAddressResolver.call({
      "title" => "CHRISTINA GARDENS HOME on 16,910 sq ft Land",
      "location" => "N/A",
      "url" => "https://mybunchofkeys.com/property/christina-gardens-home-on-16910-sq-ft-land/"
    })

    assert_equal "Christina Gardens", result.city
    assert_equal "Trinidad", result.state
    assert_no_match(/N\/A/i, result.address)
    assert_no_match(
      /N\/A/i,
      BokAddressResolver.format_address(address: result.address, city: result.city, state: result.state, zip: "")
    )
  end

  test "does not chop titles on thousands-separator commas" do
    result = BokAddressResolver.call({
      "title" => "CHRISTINA GARDENS HOME on 16,910 sq ft Land",
      "location" => "N/A"
    })

    refute_match(/HOME on 16\z/, result.address)
  end

  test "splits street and city from Debe location" do
    result = BokAddressResolver.call({
      "title" => "HOME FOR SALE - Wellington Gardens, Debe",
      "location" => "Debe, N/A",
      "url" => "https://mybunchofkeys.com/property/home-for-sale-wellington-gardens-debe/"
    })

    assert_equal "Debe", result.city
    assert_match(/Wellington/i, result.address)
  end

  test "sets Barbados from title when location is N/A" do
    result = BokAddressResolver.call({
      "title" => "FOR SALE - Hilbury Estate, St. George, Barbados",
      "location" => "N/A"
    })

    assert_equal "Barbados", result.state
    assert_equal "St. George", result.city
    assert_match(/Hilbury/i, result.address)
  end

  test "prefers post-dash street over House For Sale lead" do
    result = BokAddressResolver.call({
      "title" => "House For Sale - Cassia Drive Ext, Petit Valley - TTD$3.2M",
      "location" => "Alyce Glen Diego Martin Petit Valley",
      "url" => "https://mybunchofkeys.com/property/house-for-rent-cassia-drive-ext-petit-valleytt/",
      "description" => "House For Sale – Cassia Drive Ext, Petit Valley – TTD$3.2M Spacious home"
    })

    assert_match(/Cassia Drive/i, result.address)
    assert_no_match(/House For Sale/i, result.address)
    assert_match(/Petit Valley|Alyce Glen/i, result.city)
  end

  test "mines street from description when title is marketing" do
    result = BokAddressResolver.call({
      "title" => "HOUSE FOR SALE - CHAMPS FLEURS",
      "location" => "Champs Fleurs",
      "description" => "Daniel Drive, Champs Fleurs A beautiful 2 Storey detached house"
    })

    assert_equal "Daniel Drive", result.address
    assert_equal "Champs Fleurs", result.city
  end

  test "mines Located on street phrases" do
    result = BokAddressResolver.call({
      "title" => "Prime Property in Woodbrook: Ideal for Residential or Commercial Use!",
      "location" => "Woodbrook",
      "description" => "Located on Luis Street, this versatile property is perfect"
    })

    assert_equal "Luis Street", result.address
    assert_equal "Woodbrook", result.city
  end

  test "sets Tobago from location and keeps Darrel Spring community" do
    result = BokAddressResolver.call({
      "title" => "Income Generating Investment Property Tobago",
      "location" => "Darrel Spring, Scarborough",
      "description" => "Darrell Spring, Tobago Exceptional Investment Opportunity"
    })

    assert_equal "Tobago", result.state
    assert_match(/Darrel+ Spring/i, result.city)
    assert_no_match(/Income Generating/i, result.address)
  end
end
