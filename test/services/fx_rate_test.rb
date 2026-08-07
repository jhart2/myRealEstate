require "test_helper"

class FxRateTest < ActiveSupport::TestCase
  class FakeClient
    def configured? = true

    def chat(**)
      {
        content: {
          as_of: "2026-08-06",
          rates_to_ttd: { "USD" => "6.82", "CAD" => "5.05" },
          notes: "test"
        }.to_json,
        usage: {},
        model: "fake",
        raw: {}
      }
    end
  end

  setup { FxRate.clear_cache! }
  teardown { FxRate.clear_cache! }

  test "refresh stores openai rates in memo" do
    table = FxRate.refresh!(client: FakeClient.new)
    assert_equal BigDecimal("6.82"), table["USD"]
    assert_equal BigDecimal("5.05"), table["CAD"]
    assert_equal BigDecimal("6.82"), FxRate.to_ttd("USD")
  end

  test "falls back when refresh unavailable and memo empty" do
    client = Object.new
    def client.configured? = false

    assert_raises(FxRate::Error) { FxRate.refresh!(client: client) }
    assert_equal FxRate::FALLBACK["USD"], FxRate.to_ttd("USD")
  end
end
