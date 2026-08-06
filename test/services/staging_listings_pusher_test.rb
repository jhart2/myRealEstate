require "test_helper"

class StagingListingsPusherTest < ActiveSupport::TestCase
  test "disabled in test environment by default" do
    assert_equal false, StagingListingsPusher.enabled?
  end

  test "raises when JSON is missing" do
    error = assert_raises(StagingListingsPusher::PushError) do
      StagingListingsPusher.push!(Rails.root.join("tmp/does-not-exist-#{SecureRandom.hex(4)}.json"))
    end
    assert_match(/not found/i, error.message)
  end
end
