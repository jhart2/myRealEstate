require "test_helper"

class TruncatedDescriptionTest < ActiveSupport::TestCase
  test "detects ellipsis endings" do
    assert TruncatedDescription.ellipsis?("Nice home with a pool...")
    assert TruncatedDescription.ellipsis?("Cut short…")
    assert TruncatedDescription.suspect?("Cut short…")
    refute TruncatedDescription.ellipsis?("Complete sentence.")
  end

  test "detects historic ~1200 mid-cuts without sentence end" do
    body = ("word " * 230).strip # ~1150
    body = body[0, 1200] + " cool"
    assert TruncatedDescription.mid_cut?(body)
    assert TruncatedDescription.suspect?(body)
  end

  test "complete near-cap sentence is not mid-cut" do
    body = ("Amenity list item. " * 70).strip
    body = body[0, 1190] + "."
    refute TruncatedDescription.mid_cut?(body)
  end

  test "better_replacement prefers fuller non-truncated body" do
    old = ("x" * 1190) + " cool"
    newer = old + " and breezy in the evenings with shops nearby."
    assert TruncatedDescription.better_replacement?(old, newer)
    refute TruncatedDescription.better_replacement?(newer, old)
  end
end
