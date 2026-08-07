require "test_helper"

class ListingCopyApplierTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(payload)
      @payload = payload
    end

    def chat(**)
      {
        content: JSON.generate(@payload),
        model: "fake",
        usage: { "total_tokens" => 3 },
        raw: {}
      }
    end
  end

  setup do
    @agent = Agent.create!(
      name: "Copy Apply Agent",
      title: "Agent",
      email: "copy-apply-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  def build_property(**overrides)
    Property.create!({
      agent: @agent,
      title: "Alexander Road Home",
      address: "Alexander Road",
      city: "Vistabella",
      state: "Trinidad",
      price_cents: 440_000_000,
      tag: "sale",
      property_type: "House",
      status: "active",
      beds: 5,
      baths: 4,
      sqft: 4000,
      description: "This spacious 5 bedroom, 4 bathroom residence on Alexander Road.",
      bok_id: "BOK-TEST-#{SecureRandom.hex(4)}",
      source_url: "https://example.com/#{SecureRandom.hex(4)}"
    }.merge(overrides))
  end

  test "records silent baths drift as mismatch and skip?" do
    payload = {
      "cleaned" => {
        "title" => "Spacious Family Home on Alexander Road, Vistabella",
        "address" => "Alexander Road",
        "city" => "Vistabella",
        "state" => "Trinidad",
        "description" => "This spacious 5 bedroom, 4.5 bathroom residence on Alexander Road.",
        "beds" => 5,
        "baths" => 4.5,
        "sqft" => 4000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 1.0, "mismatches" => [], "notes" => [] }
    }

    result = ListingCopyCleaner.call(
      {
        title: "House For Sale - Alexander Road",
        address: "Alexander Road",
        city: "Vistabella",
        state: "Trinidad",
        description: "This spacious 5 bedroom, 4.5 bathroom residence on Alexander Road.",
        beds: 5,
        baths: 4,
        sqft: 4000,
        property_type: "House",
        tag: "sale"
      },
      client: FakeClient.new(payload)
    )

    assert result.mismatches?
    assert result.skip?
    refute result.applyable?
    baths_row = result.verification["mismatches"].find { |row| row["field"] == "baths" }
    assert baths_row
    assert_match(/Silent baths change/, baths_row["note"])
    assert_equal "mismatch", result.status
  end

  test "applier skips mismatches and sets copy_needs_review with scenario" do
    property = build_property
    original_title = property.title

    payload = {
      "cleaned" => {
        "title" => "Spacious Family Home on Alexander Road, Vistabella",
        "address" => "Alexander Road",
        "city" => "Vistabella",
        "state" => "Trinidad",
        "description" => "Updated description with 4.5 baths.",
        "beds" => 5,
        "baths" => 4.5,
        "sqft" => 4000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => { "status" => "ok", "confidence" => 0.95, "mismatches" => [], "notes" => [] }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.skipped?
    refute outcome.applied?
    assert property.copy_needs_review
    assert_equal original_title, property.title
    assert_equal 4, property.baths
    assert_match(/baths/i, property.copy_review_notes["scenario"].to_s)
    assert_equal "mismatch", property.copy_review_notes["status"]
  end

  test "OpenAI path flags size rematch for dry daisy chain" do
    property = build_property(
      title: "House for Sale - Maracas Gardens",
      description: "Tri level house on 22,875 sq ft of land. House size 6,000 sq ft with views.",
      sqft: 22875,
      lot_sqft: 22875,
      baths: 3
    )

    payload = {
      "cleaned" => {
        "title" => "Spacious Family Home with Views in Maracas Gardens, St Joseph",
        "address" => "Maracas Gardens",
        "city" => "St Joseph",
        "state" => "Trinidad",
        "description" => "Tri-level house on 22,875 sq ft of land with a 6,000 sq ft home and views.",
        "beds" => 5,
        "baths" => 3,
        "sqft" => 6000,
        "lot_sqft" => 22875,
        "acres" => 0.5251,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          {
            "field" => "sqft",
            "model" => 22875,
            "from_description" => 6000,
            "note" => "Imported sqft was land size; house size stated as 6,000 sq ft."
          }
        ],
        "notes" => []
      }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.skipped?
    assert property.copy_needs_review
    assert_equal 22875, property.sqft

    stats = ListingCopyApplier.reprocess_safe_size_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal 6000, property.sqft
    assert_equal 22875, property.lot_sqft
    assert_equal "safe_size_rematch", property.copy_review_notes["policy"]
  end

  test "reprocess_safe_size_flags applies stored previews for classic remines" do
    property = build_property(
      title: "Gulf View House",
      description: "Building size 3,337 sq ft on 5,965 sq ft of land.",
      sqft: 5965,
      lot_sqft: nil,
      baths: 3,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          {
            "field" => "sqft",
            "model" => 5965,
            "from_description" => 3337,
            "note" => "Imported sqft was land size; building size is 3,337 sq ft."
          },
          {
            "field" => "lot_sqft",
            "model" => nil,
            "from_description" => 5965,
            "note" => "Lot size stated in description."
          }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Family Home in Gulf View, La Romaine",
          "address" => "Gulf View",
          "city" => "La Romaine",
          "state" => "Trinidad",
          "description" => "Building size 3,337 sq ft on 5,965 sq ft of land.",
          "beds" => 5,
          "baths" => 3,
          "sqft" => 3337,
          "lot_sqft" => 5965,
          "acres" => 0.137,
          "property_type" => "House",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_size_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal 3337, property.sqft
    assert_equal 5965, property.lot_sqft
  end

  test "OpenAI path flags half-bath rematch for dry daisy chain" do
    property = build_property(
      title: "Alexander Road Home",
      description: "This spacious 5 bedroom, 4.5 bathroom residence on Alexander Road.",
      baths: 4,
      sqft: 4000
    )

    payload = {
      "cleaned" => {
        "title" => "House on Alexander Road, Vistabella",
        "address" => "Alexander Road",
        "city" => "Vistabella",
        "state" => "Trinidad",
        "description" => "This spacious 5 bedroom, 4.5 bathroom residence on Alexander Road.",
        "beds" => 5,
        "baths" => 4.5,
        "sqft" => 4000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 1.0,
        "mismatches" => [
          {
            "field" => "baths",
            "model" => 4,
            "from_description" => 4.5,
            "note" => "Silent baths change 4 → 4.5 without verification note"
          }
        ],
        "notes" => []
      }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.skipped?
    assert property.copy_needs_review
    assert_equal 4, property.baths

    stats = ListingCopyApplier.reprocess_safe_half_bath_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal 4.5, property.baths
    assert_equal "safe_half_bath_rematch", property.copy_review_notes["policy"]
  end

  test "reprocess_safe_flags applies stored half-bath previews" do
    property = build_property(
      title: "One Woodbrook Ground Floor",
      description: "Rare opportunity to own a 3 bedroom, 3.5 bathroom apartment.",
      baths: 3,
      beds: 3,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.95,
        "mismatches" => [
          {
            "field" => "baths",
            "model" => 3,
            "from_description" => 3.5,
            "note" => "Description states 3.5 bathrooms, but imported value was 3."
          }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Spacious 3-Bedroom Ground Floor Apartment in Woodbrook",
          "address" => "One Woodbrook Place",
          "city" => "Woodbrook",
          "state" => "Trinidad",
          "description" => "Rare opportunity to own a 3 bedroom, 3.5 bathroom apartment.",
          "beds" => 3,
          "baths" => 3.5,
          "sqft" => nil,
          "property_type" => "Apartment",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_half_bath_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal 3.5, property.baths
    assert_equal "safe_half_bath_rematch", property.copy_review_notes["policy"]
  end

  test "daisy chain applies size+half-bath combo as its own dry link" do
    property = build_property(
      title: "House on Saddle Road",
      description: "4 bedroom, 3.5 bathroom home. Building size 3,000 sqft on 8,000 sqft of land.",
      beds: 4,
      baths: 3,
      sqft: 8000,
      lot_sqft: nil,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.92,
        "mismatches" => [
          {
            "field" => "sqft",
            "model" => 8000,
            "from_description" => 3000,
            "note" => "Imported sqft was land size; building size stated as 3,000 sqft."
          },
          {
            "field" => "lot_sqft",
            "model" => nil,
            "from_description" => 8000,
            "note" => "Lot size was stated in the description."
          },
          {
            "field" => "baths",
            "model" => 3,
            "from_description" => 3.5,
            "note" => "Description states 3.5 bathrooms."
          }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Spacious 4-Bed Family Home on Saddle Road, Maraval",
          "address" => "Saddle Road",
          "city" => "Maraval",
          "state" => "Trinidad",
          "description" => "4 bedroom, 3.5 bathroom home with 3,000 sqft building on 8,000 sqft land.",
          "beds" => 4,
          "baths" => 3.5,
          "sqft" => 3000,
          "lot_sqft" => 8000,
          "acres" => 0.183,
          "property_type" => "House",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.daisy_chain_safe_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    assert_equal 1, stats[:steps]["safe_size_and_half_bath_rematch"][:applied]
    assert_equal 0, stats[:remaining]
    refute property.copy_needs_review
    assert_equal 3000, property.sqft
    assert_equal 8000, property.lot_sqft
    assert_equal 3.5, property.baths
    assert_equal "safe_size_and_half_bath_rematch", property.copy_review_notes["policy"]
  end

  test "applier writes cleaned fields when verification is ok with no drifts" do
    property = build_property(baths: 4)

    payload = {
      "cleaned" => {
        "title" => "Family Home on Alexander Road, Vistabella",
        "address" => "Alexander Road",
        "city" => "Vistabella",
        "state" => "Trinidad",
        "description" => "A clean five bedroom, four bathroom family home on Alexander Road in Vistabella.",
        "beds" => 5,
        "baths" => 4,
        "sqft" => 4000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => [ "Patio" ]
      },
      "verification" => { "status" => "ok", "confidence" => 0.99, "mismatches" => [], "notes" => [] }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.applied?
    refute outcome.skipped?
    refute property.copy_needs_review
    assert_equal "Family Home on Alexander Road, Vistabella", property.title
    assert_match(/family home/i, property.description_plain)
  end

  test "OpenAI path flags title-strong type for dry daisy chain" do
    property = build_property(
      title: "LAND FOR SALE - 5 Acres Aranguez",
      property_type: "House",
      beds: 3,
      baths: 2,
      sqft: 20_000,
      description: "Vacant land for sale measuring approximately 20,000 sqft."
    )

    payload = {
      "cleaned" => {
        "title" => "5-Acre Aranguez Land Parcel for Sale",
        "address" => "Aranguez",
        "city" => "Aranguez",
        "state" => "Trinidad",
        "description" => "Vacant land for sale measuring approximately 20,000 sqft.",
        "beds" => nil,
        "baths" => nil,
        "sqft" => nil,
        "lot_sqft" => 20_000,
        "property_type" => "Land",
        "tag" => "sale",
        "features" => []
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          { "field" => "property_type", "model" => "House", "from_description" => "Land", "note" => "Title says land" },
          { "field" => "sqft", "model" => 20_000, "from_description" => nil, "note" => "Lot not building" },
          { "field" => "beds", "model" => 3, "from_description" => nil, "note" => "Land" }
        ],
        "notes" => []
      }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.skipped?
    assert property.copy_needs_review
    assert_equal "House", property.property_type

    stats = ListingCopyApplier.reprocess_safe_type_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal "Land", property.property_type
    assert_equal 20_000, property.lot_sqft
    assert_nil property.beds
    assert_equal "safe_type_rematch", property.copy_review_notes["policy"]
  end

  test "title-strong maps Apartment Building to Apartment via dry type link" do
    property = build_property(
      title: "Apartment Building for Sale Woodbrook",
      property_type: "House",
      description: "Income-producing apartment building.",
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          { "field" => "property_type", "model" => "House", "from_description" => "Apartment Building", "note" => "Building" }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Woodbrook Apartment Building for Sale",
          "address" => "Woodbrook",
          "city" => "Port of Spain",
          "state" => "Trinidad",
          "description" => "Income-producing apartment building.",
          "beds" => 5,
          "baths" => 4,
          "sqft" => 4000,
          "property_type" => "Apartment Building",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_type_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    assert_equal "Apartment", property.property_type
    assert_equal "safe_type_rematch", property.copy_review_notes["policy"]
  end

  test "rejects type rematch without title keyword" do
    property = build_property(
      title: "La Seiva Maraval Investment Opportunity",
      property_type: "Apartment",
      description: "Great investment house opportunity."
    )

    payload = {
      "cleaned" => {
        "title" => "La Seiva Maraval Investment Opportunity",
        "address" => "La Seiva",
        "city" => "Maraval",
        "state" => "Trinidad",
        "description" => "Great investment house opportunity.",
        "beds" => 5,
        "baths" => 4,
        "sqft" => 4000,
        "property_type" => "House",
        "tag" => "sale",
        "features" => []
      },
      "verification" => {
        "status" => "mismatch",
        "confidence" => 0.7,
        "mismatches" => [
          { "field" => "property_type", "model" => "Apartment", "from_description" => "House", "note" => "Sounds like house" }
        ],
        "notes" => []
      }
    }

    outcome = ListingCopyApplier.call(property, client: FakeClient.new(payload))
    property.reload

    assert outcome.skipped?
    assert property.copy_needs_review
    assert_equal "Apartment", property.property_type
  end

  test "rejects garbage proposed types" do
    assert_nil ListingCopyApplier.normalize_proposed_type("3-bedroom, 2-bathroom home")
    assert_equal "Apartment", ListingCopyApplier.normalize_proposed_type("Apartment Building")
    assert_equal "Commercial", ListingCopyApplier.normalize_proposed_type("Commercial")
  end

  test "reprocess_safe_flags applies title-strong type previews" do
    property = build_property(
      title: "COMMERCIAL Building for Sale - Mucurapo",
      property_type: "House",
      beds: 0,
      baths: 2,
      sqft: 5000,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.88,
        "mismatches" => [
          { "field" => "property_type", "model" => "House", "from_description" => "Commercial", "note" => "Commercial" }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Mucurapo Commercial Building for Sale",
          "address" => "Mucurapo",
          "city" => "Port of Spain",
          "state" => "Trinidad",
          "description" => "Commercial building for sale.",
          "beds" => 0,
          "baths" => 2,
          "sqft" => 5000,
          "property_type" => "Commercial",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal "Commercial", property.property_type
    assert_equal "safe_type_rematch", property.copy_review_notes["policy"]
  end

  test "dry sparse link applies title+description and keeps features" do
    property = build_property(
      title: "LUXURY HOME FOR SALE - eighteen Moka",
      description: "About the Region Moka … long region blurb.",
      beds: 2,
      baths: 3,
      sqft: nil,
      features: [ "Pool", "Garage", "AC" ],
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "needs_review",
        "confidence" => 0.8,
        "mismatches" => [],
        "notes" => [ "Sparse source description — factual blurb only; amenities cleared" ],
        "cleaned_preview" => {
          "title" => "Brand New Luxury Home in Moka, Trinidad",
          "address" => "Moka",
          "city" => "Maraval",
          "state" => "Trinidad",
          "description" => "Brand new luxury home in Moka.",
          "beds" => 2,
          "baths" => 3,
          "sqft" => nil,
          "property_type" => "House",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_sparse_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal "Brand New Luxury Home in Moka, Trinidad", property.title
    assert_equal "Brand new luxury home in Moka.", property.description_plain
    assert_equal [ "Pool", "Garage", "AC" ], property.features
    assert_equal "safe_sparse_copy_rematch", property.copy_review_notes["policy"]
    assert property.copy_review_notes["kept_features"]
  end

  test "sparse link skips when field mismatches exist" do
    property = build_property(
      title: "Aquaview Lot",
      sqft: 21_125,
      property_type: "Land",
      beds: nil,
      baths: nil,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "needs_review",
        "mismatches" => [
          { "field" => "sqft", "model" => 21_125, "from_description" => nil, "note" => "lot" }
        ],
        "notes" => [ "Sparse source description — factual blurb only; amenities cleared" ],
        "cleaned_preview" => {
          "title" => "Prime Lot in Carenage",
          "description" => "Residential lot.",
          "beds" => nil,
          "baths" => nil,
          "sqft" => nil,
          "lot_sqft" => 21_125,
          "property_type" => "Land",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_sparse_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 0, stats[:applied]
    assert property.copy_needs_review
  end

  test "dry nil-fill specs link applies land size + literal empty beds/baths" do
    property = build_property(
      title: "FOR SALE: BRAND NEW 3 BEDROOM HOUSE",
      description: "Brand-new home on 5,000 sq. ft. of land. 3 bedrooms and 2 full bathrooms.",
      beds: nil,
      baths: nil,
      sqft: 5001,
      lot_sqft: 5000,
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "confidence" => 0.9,
        "mismatches" => [
          { "field" => "beds", "model" => nil, "from_description" => 3, "note" => "stated" },
          { "field" => "baths", "model" => nil, "from_description" => 2, "note" => "stated" },
          { "field" => "sqft", "model" => 5001, "from_description" => nil, "note" => "lot misclassified as building" }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Brand New 3-Bedroom House in Las Lomas",
          "address" => "Araf Drive",
          "city" => "Las Lomas",
          "state" => "Trinidad",
          "description" => "Brand-new home on 5,000 sq. ft. of land with 3 bedrooms and 2 full bathrooms.",
          "beds" => 3,
          "baths" => 2,
          "sqft" => nil,
          "lot_sqft" => 5000,
          "property_type" => "House",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_nil_fill_specs_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 1, stats[:applied]
    refute property.copy_needs_review
    assert_equal 3, property.beds
    assert_equal 2, property.baths
    assert_nil property.sqft
    assert_equal 5000, property.lot_sqft
    assert_equal "safe_size_and_nil_fill_specs_rematch", property.copy_review_notes["policy"]
  end

  test "nil-fill specs skips multi-unit bed aggregates without literal single-home evidence" do
    property = build_property(
      title: "FULLY OCCUPIED APARTMENT BUILDING Freeport",
      description: "5 one-bedroom and 5 three-bedroom units on 8,000 sq ft of land.",
      beds: nil,
      baths: nil,
      sqft: 8000,
      lot_sqft: 8000,
      property_type: "Townhouse",
      copy_needs_review: true,
      copy_review_notes: {
        "status" => "mismatch",
        "mismatches" => [
          { "field" => "beds", "model" => nil, "from_description" => 15, "note" => "sum of units" },
          { "field" => "baths", "model" => nil, "from_description" => 12, "note" => "sum" },
          { "field" => "sqft", "model" => 8000, "from_description" => nil, "note" => "lot" }
        ],
        "notes" => [],
        "cleaned_preview" => {
          "title" => "Income Building Freeport",
          "description" => "Fully occupied building.",
          "beds" => 15,
          "baths" => 12,
          "sqft" => nil,
          "lot_sqft" => 8000,
          "property_type" => "Townhouse",
          "tag" => "sale",
          "features" => []
        }
      }
    )

    stats = ListingCopyApplier.reprocess_safe_nil_fill_specs_flags!(Property.where(id: property.id))
    property.reload

    assert_equal 0, stats[:applied]
    assert property.copy_needs_review
  end
end
