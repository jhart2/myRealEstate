require "test_helper"

class ListingDescriptionRichFormatterTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(structure:, html:)
      @structure = structure
      @html = html
      @calls = 0
    end

    attr_reader :calls

    def chat(**)
      @calls += 1
      payload = @calls == 1 ? @structure : { "html" => @html }
      {
        content: JSON.generate(payload),
        model: "fake",
        usage: { "total_tokens" => 5 },
        raw: {}
      }
    end
  end

  setup do
    @agent = Agent.create!(
      name: "Rich Format Agent",
      title: "Agent",
      email: "rich-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
    @previous = ENV["LISTING_COPY_RICH_HTML"]
    ENV["LISTING_COPY_RICH_HTML"] = "1"
  end

  teardown do
    if @previous.nil?
      ENV.delete("LISTING_COPY_RICH_HTML")
    else
      ENV["LISTING_COPY_RICH_HTML"] = @previous
    end
  end

  def build_property(**overrides)
    Property.create!({
      agent: @agent,
      title: "Coral Gardens Home",
      address: "Coral Gardens",
      city: "Diego Martin",
      state: "Trinidad",
      price_cents: 2_000_000_00,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "A bright 3 bedroom home. Features: pool, garage, and covered patio. Quiet street near schools.",
      bok_id: "BOK-RICH-#{SecureRandom.hex(3)}",
      source_url: "https://example.com/#{SecureRandom.hex(3)}"
    }.merge(overrides))
  end

  test "skips when isolation flag is off" do
    ENV["LISTING_COPY_RICH_HTML"] = "0"
    property = build_property
    outcome = ListingDescriptionRichFormatter.call(property, client: FakeClient.new(structure: {}, html: "<div/>"))
    assert outcome.skipped?
    assert_match(/LISTING_COPY_RICH_HTML/, outcome.error)
  end

  test "dry run returns polished html without writing" do
    property = build_property
    before = property.description_plain

    client = FakeClient.new(
      structure: {
        "sections" => [
          { "id" => "intro", "heading" => "Overview", "summary" => "Bright home", "bullet_candidates" => [] },
          { "id" => "features", "heading" => "Features", "summary" => "Amenities", "bullet_candidates" => %w[pool garage patio] }
        ],
        "tone_notes" => "grounded"
      },
      html: <<~HTML
        <div>
          <p>A bright 3 bedroom home on a quiet street near schools.</p>
          <h2>Features</h2>
          <ul>
            <li><strong>Pool</strong></li>
            <li><strong>Garage</strong></li>
            <li><strong>Covered patio</strong></li>
          </ul>
        </div>
      HTML
    )

    outcome = ListingDescriptionRichFormatter.call(property, client: client, apply: false)
    property.reload

    refute outcome.skipped?
    refute outcome.applied?
    assert_equal 2, client.calls
    assert_match(/<h2>Features<\/h2>/, outcome.html)
    assert_equal before, property.description_plain
  end

  test "apply writes sanitized html into action text" do
    property = build_property
    client = FakeClient.new(
      structure: { "sections" => [], "tone_notes" => "" },
      html: '<div><h2>Features</h2><ul><li><strong>Pool</strong></li></ul><script>alert(1)</script></div>'
    )

    outcome = ListingDescriptionRichFormatter.call(property, client: client, apply: true)
    property.reload

    assert outcome.applied?
    assert_match(/Features/, property.description_plain)
    assert_match(/<h2>Features<\/h2>/, property.description_html)
    refute_match(/script/i, property.description_html)
  end
end
