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

  test "detects keyword heading opportunities from source labels" do
    plain = <<~TEXT
      Intro copy about the home.
      Property Features: pool, garage
      Parking & Amenities: visitor spots
      Asking: $1M
      Call/WhatsApp: 555
      Location Highlights: near schools
      About the Region
      Fairways is gated.
    TEXT

    hits = ListingDescriptionRichFormatter.detect_heading_opportunities(plain)
    headings = hits.map { |h| h[:heading] }

    assert_includes headings, "Property Features"
    assert_includes headings, "Parking & Amenities"
    assert_includes headings, "Location Highlights"
    assert_includes headings, "About the Region"
    refute_includes headings, "Asking"
    refute_includes headings, "Call/WhatsApp"
    assert_equal 1, hits.count { |h| h[:kind] == "features" }
    assert hits.find { |h| h[:heading] == "About the Region" }[:demote]
  end

  test "bespoke taxonomy is fixed and always allowed" do
    assert_equal [
      "Property Features",
      "Parking & Amenities",
      "Location Highlights"
    ], ListingDescriptionRichFormatter::BESPOKE_HEADING_LABELS

    assert ListingDescriptionRichFormatter.heading_allowed?("Property Features")
    assert ListingDescriptionRichFormatter.heading_allowed?("Parking & Amenities")
    assert ListingDescriptionRichFormatter.heading_allowed?("Location Highlights")
    refute ListingDescriptionRichFormatter.heading_allowed?("Key Features")
    refute ListingDescriptionRichFormatter.heading_allowed?("Prime Location")
  end

  test "enforce remaps invented titles onto bespoke headlines" do
    property = build_property(
      description: "Nice home with pool and covered parking near Westmall."
    )
    client = FakeClient.new(
      structure: {
        "sections" => [
          {
            "id" => "highlights",
            "heading" => "Property Highlights",
            "bullet_candidates" => [ "Nice home" ]
          },
          {
            "id" => "amenities",
            "heading" => "Key Features",
            "bullet_candidates" => [ "covered parking", "pool" ]
          },
          {
            "id" => "location",
            "heading" => "Prime Location",
            "bullet_candidates" => [ "near Westmall" ]
          }
        ],
        "tone_notes" => ""
      },
      html: <<~HTML
        <div>
          <p>Nice home with pool and covered parking near Westmall.</p>
          <h2>Property Features</h2>
          <ul><li>Nice home</li></ul>
          <h2>Parking &amp; Amenities</h2>
          <ul><li>covered parking</li><li>pool</li></ul>
          <h2>Location Highlights</h2>
          <ul><li>near Westmall</li></ul>
        </div>
      HTML
    )

    outcome = ListingDescriptionRichFormatter.call(property, client: client, apply: false)
    refute outcome.skipped?
    headings = Array(outcome.structure["sections"]).map { |s| s["heading"] }
    assert_includes headings, "Property Features"
    assert_includes headings, "Parking & Amenities"
    assert_includes headings, "Location Highlights"
    refute_includes headings, "Property Highlights"
    refute_includes headings, "Key Features"
    refute_includes headings, "Prime Location"
    assert_match(/Property Features/, outcome.html)
    assert_match(/Parking &amp; Amenities|Parking & Amenities/, outcome.html)
    assert_match(/Location Highlights/, outcome.html)
  end

  test "ground_html strips invented bullets and non-bespoke headings" do
    source = "3 bedroom home with a pool and covered parking. Gated compound."
    html = <<~HTML
      <div>
        <p>A lovely home.</p>
        <h2>Property Features</h2>
        <ul>
          <li><strong>3 bedroom</strong> home</li>
          <li><strong>Rooftop tennis court</strong> with lighting</li>
          <li><strong>Pool</strong></li>
        </ul>
        <h2>Prime Location</h2>
        <ul>
          <li><strong>Covered parking</strong></li>
        </ul>
      </div>
    HTML

    result = ListingDescriptionRichFormatter.ground_html(html, source, opportunities: [])
    refute_match(/tennis/i, result[:html])
    refute_match(/Prime Location/i, result[:html])
    assert_match(/Property Features/i, result[:html])
    assert_match(/Pool/i, result[:html])
    assert_match(/Covered parking/i, result[:html])
    assert_includes result[:stripped_bullets].join(" "), "tennis"
    assert_includes result[:stripped_headings], "Prime Location"
  end

  test "ground_html drops empty bespoke headings" do
    source = "3 bedroom home with a pool."
    html = <<~HTML
      <div>
        <h2>Property Features</h2>
        <ul><li>3 bedroom</li><li>pool</li></ul>
        <h2>Location Highlights</h2>
        <ul></ul>
      </div>
    HTML

    result = ListingDescriptionRichFormatter.ground_html(html, source)
    assert_match(/Property Features/, result[:html])
    refute_match(/Location Highlights/, result[:html])
  end

  test "phrase_grounded keeps labeled claims that appear in source" do
    source = "Exterior features include an electronic gate, front yard parking for two additional vehicles."
    assert ListingDescriptionRichFormatter.phrase_grounded?(
      "Electronic gate: Exterior features include an electronic gate.",
      source
    )
    assert ListingDescriptionRichFormatter.phrase_grounded?("front yard parking", source)
    refute ListingDescriptionRichFormatter.phrase_grounded?("Rooftop tennis court", source)
    refute ListingDescriptionRichFormatter.phrase_grounded?("wine cellar with tasting room", source)
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
          { "id" => "intro", "heading" => "", "summary" => "Bright home", "bullet_candidates" => [] },
          {
            "id" => "features",
            "heading" => "Property Features",
            "bullet_candidates" => %w[pool garage patio]
          }
        ],
        "tone_notes" => "grounded"
      },
      html: <<~HTML
        <div>
          <p>A bright 3 bedroom home on a quiet street near schools.</p>
          <h2>Property Features</h2>
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
    assert_match(/<h2>Property Features<\/h2>/, outcome.html)
    assert_equal before, property.description_plain
  end

  test "apply writes sanitized html into action text" do
    property = build_property
    client = FakeClient.new(
      structure: {
        "sections" => [
          {
            "id" => "features",
            "heading" => "Property Features",
            "bullet_candidates" => [ "Pool" ]
          }
        ],
        "tone_notes" => ""
      },
      html: '<div><h2>Property Features</h2><ul><li><strong>Pool</strong></li></ul><script>alert(1)</script></div>'
    )

    outcome = ListingDescriptionRichFormatter.call(property, client: client, apply: true)
    property.reload

    assert outcome.applied?
    assert_match(/Property Features/, property.description_plain)
    assert_match(/<h2>Property Features<\/h2>/, property.description_html)
    refute_match(/script/i, property.description_html)
  end
end
