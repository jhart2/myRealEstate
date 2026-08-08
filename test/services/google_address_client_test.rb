require "test_helper"

class GoogleAddressClientTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @client = GoogleAddressClient.new(api_key: "test-key")
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "geocode caches a Hash and returns a Result" do
    canned = GoogleAddressClient::Result.new(
      formatted_address: "1 Test St, Port of Spain, Trinidad and Tobago",
      address: "1 Test St",
      city: "Port of Spain",
      state: "Trinidad",
      zip: nil,
      latitude: 10.5,
      longitude: -61.5,
      place_id: "abc",
      location_type: "ROOFTOP",
      confidence: 95,
      source: "geocoding",
      raw: { "types" => [ "street_address" ] }
    )
    calls = 0
    @client.define_singleton_method(:geocode_uncached) do |**|
      calls += 1
      raise "should use cache" if calls > 1

      canned
    end

    first = @client.geocode(query: "1 Test St, Port of Spain", region: "TT")
    assert_kind_of GoogleAddressClient::Result, first
    assert_equal "1 Test St", first.address

    second = @client.geocode(query: "1 Test St, Port of Spain", region: "TT")
    assert_kind_of GoogleAddressClient::Result, second
    assert_equal first.address, second.address
    assert_equal 1, calls

    # Cache payload must be a Hash (safe across Zeitwerk reloads), not a Result.
    key = [
      "google_geocode/v2",
      Digest::SHA1.hexdigest([ "1 test st, port of spain", "tt", "" ].join("|"))
    ]
    assert_kind_of Hash, Rails.cache.read(key)
  end

  test "result hash round-trips through Marshal for Rails.cache" do
    result = GoogleAddressClient::Result.new(
      formatted_address: "x",
      address: "y",
      city: "z",
      state: "Trinidad",
      zip: nil,
      latitude: 1.0,
      longitude: 2.0,
      place_id: "p",
      location_type: "ROOFTOP",
      confidence: 90,
      source: "geocoding",
      raw: { "types" => [ "route" ] }
    )
    dumped = Marshal.dump(result.to_h)
    loaded = Marshal.load(dumped)
    assert_kind_of Hash, loaded
    restored = GoogleAddressClient::Result.new(
      **loaded.transform_keys(&:to_sym).slice(*GoogleAddressClient::Result.members)
    )
    assert_equal result.address, restored.address
  end
end
