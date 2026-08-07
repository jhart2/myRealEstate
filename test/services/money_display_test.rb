require "test_helper"

class MoneyDisplayTest < ActiveSupport::TestCase
  setup do
    FxRate.clear_cache!
    FxRate.stub!(usd: "6.75", cad: "5.0")
  end

  teardown { FxRate.clear_cache! }

  test "stored TTD amounts display unchanged in TTD" do
    cents = 10_000_000_00 # TT$10,000,000
    assert_equal "TT$10,000,000", MoneyDisplay.format(cents, currency: "TTD")
  end

  test "stored TTD amounts convert down into USD" do
    cents = 10_000_000_00 # TT$10,000,000
    assert_equal "$1,481,481", MoneyDisplay.format(cents, currency: "USD")
  end

  test "base currency defaults to TTD" do
    assert_equal "TTD", MoneyDisplay::BASE_CURRENCY
  end
end
