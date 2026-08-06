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

  test "uses Arima as city when location is street, N/A" do
    result = BokAddressResolver.call({
      "title" => "5 Bedroom Home Sierra Vista Drive, Arima",
      "location" => "Sierra Vista Drive, N/A",
      "url" => "https://mybunchofkeys.com/property/5-bedroom-home-sierra-vista-drive-arima/"
    })

    assert_equal "Arima", result.city
    assert_match(/Sierra Vista/i, result.address)
  end
end
