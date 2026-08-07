require "test_helper"

class BokLocationToolkitTest < ActiveSupport::TestCase
  test "tags split space-joined location blobs" do
    tags = BokLocationToolkit.tags("Charlieville Chin Chin Cunupia")
    assert_includes tags.map(&:downcase), "charlieville"
    assert_includes tags.map(&:downcase), "chin chin"
    assert_includes tags.map(&:downcase), "cunupia"
  end

  test "geo_queries prefer Chin Chin Road expansion" do
    queries = BokLocationToolkit.geo_queries(
      location_raw: "Charlieville Chin Chin Cunupia",
      city: "Cunupia",
      state: "Trinidad"
    )
    assert queries.any? { |q| q.match?(/chin chin road/i) }
    assert queries.first.match?(/chin chin/i)
  end

  test "place_like_photon rejects shop POIs" do
    refute BokLocationToolkit.place_like_photon?(
      type: "other", label: "St. Clair Mini Mart, Morvant"
    )
    assert BokLocationToolkit.place_like_photon?(
      type: "street", label: "Chin Chin Road, Chaguanas"
    )
  end
end
