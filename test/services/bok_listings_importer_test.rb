require "test_helper"

class BokListingsImporterTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(
      name: "Import Agent",
      title: "Listing Feed",
      email: "importer-test@example.com",
      phone: "",
      bio: "test",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  test "skips creating listings with empty image arrays" do
    path = write_feed([ belmont_classic_row ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 0, result.created
    assert_equal 1, result.skipped
    assert_equal 0, result.removed
    assert_includes result.errors.join, "no usable images"
    assert_nil Property.find_by(bok_id: "BOK-1050440")
  end

  test "skips creating listings that only have theme placeholder images" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-PLACEHOLDER",
        "url" => "https://mybunchofkeys.com/property/placeholder-only/",
        "image" => "https://mybunchofkeys.com/wp-content/themes/bok/images/default.jpg",
        "images" => [ "https://mybunchofkeys.com/wp-content/themes/bok/images/default.jpg" ]
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 0, result.created
    assert_equal 1, result.skipped
    assert_nil Property.find_by(bok_id: "BOK-PLACEHOLDER")
  end

  test "creates listings with a usable gallery" do
    path = write_feed([ good_row ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    property = Property.find_by!(bok_id: "BOK-GOOD")
    assert_equal "active", property.status
    assert_equal "House", property.property_type
    assert_equal "sale", property.tag
    assert property.image_urls.any?
    assert property.image_url.present?
  end

  test "does not re-reconcile addresses on existing listings" do
    imgs = good_row["images"]
    property = Property.create!(
      agent: @agent,
      bok_id: "BOK-GOOD",
      source_url: good_row["url"],
      title: "Archer Street Belmont Home",
      slug: "archer-street-belmont-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "99 Kept Street",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "Solid Belmont home with gallery photos.",
      image_url: imgs.first,
      image_urls: imgs,
      latitude: 10.661,
      longitude: -61.504
    )

    enrich_calls = 0
    original = ListingAddressBrain.method(:enrich)
    ListingAddressBrain.define_singleton_method(:enrich) do |*args, **kwargs|
      enrich_calls += 1
      original.call(*args, **kwargs)
    end

    begin
      path = write_feed([ good_row.merge("price" => "$1,250,000", "location" => "Different Scraped Location") ])
      result = BokListingsImporter.import!(path, agent: @agent)

      assert_equal 0, enrich_calls
      assert_equal 0, result.address_enriched
      assert_equal 1, result.updated
      assert_empty result.created_bok_ids
      assert_includes result.touched_bok_ids, "BOK-GOOD"
    ensure
      ListingAddressBrain.define_singleton_method(:enrich, original)
    end

    property.reload
    assert_equal "99 Kept Street", property.address
    assert_equal "Belmont", property.city
    assert_in_delta 10.661, property.latitude, 0.0001
    assert_in_delta(-61.504, property.longitude, 0.0001)
    assert_equal 1_250_000_00, property.price_cents
  end

  test "tracks created_bok_ids separately from updates" do
    path = write_feed([ good_row ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    assert_equal [ "BOK-GOOD" ], result.created_bok_ids
    assert_includes result.touched_bok_ids, "BOK-GOOD"
  end

  test "does not rewrite listing copy after successful apply" do
    imgs = good_row["images"]
    property = Property.create!(
      agent: @agent,
      bok_id: "BOK-GOOD",
      source_url: good_row["url"],
      title: "Archer Street Belmont Home",
      slug: "archer-street-belmont-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "99 Kept Street",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "Polished Belmont home copy.",
      image_url: imgs.first,
      image_urls: imgs,
      copy_needs_review: false,
      copy_review_notes: {
        "status" => "ok",
        "applied_at" => "2026-08-01T12:00:00Z",
        "policy" => "ok"
      }
    )

    ENV["BOK_APPLY_LISTING_COPY"] = "1"
    calls = 0
    original = ListingCopyApplier.method(:call)
    ListingCopyApplier.define_singleton_method(:call) do |*_args, **_kwargs|
      calls += 1
      ListingCopyApplier::Result.new(property: property, applied: true, skipped: false)
    end

    begin
      path = write_feed([ good_row.merge("price" => "$1,250,000") ])
      result = BokListingsImporter.import!(path, agent: @agent)

      assert_equal 0, calls
      assert_equal 0, result.copy_applied
      assert_equal 1, result.updated
    ensure
      ListingCopyApplier.define_singleton_method(:call, original)
      ENV.delete("BOK_APPLY_LISTING_COPY")
    end
  end

  test "does not rewrite listing copy when polished rich HTML is present" do
    imgs = good_row["images"]
    heading = ListingDescriptionRichFormatter::BESPOKE_HEADING_LABELS.first
    property = Property.create!(
      agent: @agent,
      bok_id: "BOK-GOOD",
      source_url: good_row["url"],
      title: "Archer Street Belmont Home",
      slug: "archer-street-belmont-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "99 Kept Street",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "<h2>#{heading}</h2><p>Site polished copy.</p>",
      image_url: imgs.first,
      image_urls: imgs
    )

    ENV["BOK_APPLY_LISTING_COPY"] = "1"
    calls = 0
    original = ListingCopyApplier.method(:call)
    ListingCopyApplier.define_singleton_method(:call) do |*_args, **_kwargs|
      calls += 1
      ListingCopyApplier::Result.new(property: property, applied: true, skipped: false)
    end

    begin
      path = write_feed([ good_row.merge("price" => "$1,250,000") ])
      result = BokListingsImporter.import!(path, agent: @agent)

      assert_equal 0, calls
      assert_equal 0, result.copy_applied
      assert_equal 1, result.updated
    ensure
      ListingCopyApplier.define_singleton_method(:call, original)
      ENV.delete("BOK_APPLY_LISTING_COPY")
    end
  end

  test "maps apartment for rent from BOK style and price" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-APT-RENT",
        "url" => "https://mybunchofkeys.com/property/cozy-apartment-for-rent/",
        "title" => "Cozy Apartment for Rent - My Bunch of Keys",
        "price" => "$4,500 / Mth",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Rent"
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    property = Property.find_by!(bok_id: "BOK-APT-RENT")
    assert_equal "Apartment", property.property_type
    assert_equal "rent", property.tag
  end

  test "dual listing with scraped monthly tip uses sale price from body" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-DUAL-TIP",
        "url" => "https://mybunchofkeys.com/property/la-riviera-10/",
        "title" => "La riviera 10 - My Bunch of Keys",
        "price" => "$4,000(USD)",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Sale",
        "description" =>
          "Waterfront living at La Riviera. For Sale: TT$8.2M For Rent: US$4,000/mth DM to book a viewing."
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)
    property = Property.find_by!(bok_id: "BOK-DUAL-TIP")

    assert_equal 1, result.created
    assert_equal "sale", property.tag
    assert_equal 8_200_000_00, property.price_cents
  end

  test "dual sale-or-rent title keeps sale when purchase price present" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-DUAL-TITLE",
        "url" => "https://mybunchofkeys.com/property/apartment-for-sale-or-rent-owp/",
        "title" => "APARTMENT FOR RENT - One Woodbrook Place - My Bunch of Keys",
        "price" => "$5,000,000",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Sale",
        "description" =>
          "Fully furnished apartment. AVAILABLE For RENT or SALE. For Sale TT$5,000,000. Rent TT$12,000/mth."
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)
    property = Property.find_by!(bok_id: "BOK-DUAL-TITLE")

    assert_equal 1, result.created
    assert_equal "sale", property.tag
    assert_equal 5_000_000_00, property.price_cents
  end

  test "cheap dwelling tip without sale figure imports as rent" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-CHEAP-USD",
        "url" => "https://mybunchofkeys.com/property/moka-maraval-3/",
        "title" => "Moka - Maraval House for sale - My Bunch of Keys",
        "price" => "$3,500(USD)",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Sale",
        "description" => "Quiet residential neighbourhood of Moka."
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)
    property = Property.find_by!(bok_id: "BOK-CHEAP-USD")

    assert_equal 1, result.created
    assert_equal "rent", property.tag
    assert_equal 3_500_00, property.price_cents
  end

  test "reconcile_offers updates mistagged dual without full reimport" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-OFFER-FIX",
        "url" => "https://mybunchofkeys.com/property/la-riviera-offer-fix/",
        "title" => "La riviera tip - My Bunch of Keys",
        "price" => "$4,000(USD)",
        "property_style" => "Apartment/Townhouse",
        "property_type" => "For Sale",
        "description" => "Waterfront. For Sale: TT$8.2M For Rent: US$4,000/mth."
      )
    ])

    # Seed wrong tip-as-sale without going through resolve_offer.
    Property.create!(
      agent: @agent,
      bok_id: "BOK-OFFER-FIX",
      source_url: "https://mybunchofkeys.com/property/la-riviera-offer-fix/",
      title: "La riviera tip",
      slug: "la-riviera-offer-fix-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "Apartment",
      status: "active",
      address: "Westmoorings",
      city: "Westmoorings",
      state: "Trinidad",
      zip: "",
      price_cents: 4_000_00,
      description: "tip",
      image_url: good_row["image"],
      image_urls: good_row["images"]
    )

    summary = BokListingsImporter.reconcile_offers!(path)
    property = Property.find_by!(bok_id: "BOK-OFFER-FIX")

    assert_equal 1, summary[:updated]
    assert_equal "sale", property.tag
    assert_equal 8_200_000_00, property.price_cents
  end

  test "dual wording with only monthly price stays rent" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-DUAL-RENT-ONLY",
        "url" => "https://mybunchofkeys.com/property/beaumont-ridge/",
        "title" => "Beaumont Ridge, Maraval for Rent or Sale - My Bunch of Keys",
        "price" => "$6,000(USD)",
        "property_style" => "House",
        "property_type" => "For Rent",
        "description" => "Exclusive gated neighbourhood. Pool with jacuzzi. Contact for viewing."
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)
    property = Property.find_by!(bok_id: "BOK-DUAL-RENT-ONLY")

    assert_equal 1, result.created
    assert_equal "rent", property.tag
    assert_equal 6_000_00, property.price_cents
  end

  test "maps land and commercial styles" do
    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-LAND",
        "url" => "https://mybunchofkeys.com/property/land-for-sale-arima/",
        "title" => "Land for Sale Arima - My Bunch of Keys",
        "property_style" => "Land",
        "property_type" => "For Sale"
      ),
      good_row.merge(
        "bok_id" => "BOK-COMM",
        "url" => "https://mybunchofkeys.com/property/warehouse-space-longdenville/",
        "title" => "Warehouse Space - My Bunch of Keys",
        "property_style" => "Commercial",
        "property_type" => "For Rent",
        "price" => "$8,000 / Mth"
      )
    ])

    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 2, result.created
    land = Property.find_by!(bok_id: "BOK-LAND")
    commercial = Property.find_by!(bok_id: "BOK-COMM")
    assert_equal "Land", land.property_type
    assert_equal "sale", land.tag
    assert_equal "Commercial", commercial.property_type
    assert_equal "rent", commercial.tag
  end

  test "destroys an existing public listing when re-import has no usable images" do
    existing = Property.create!(
      agent: @agent,
      bok_id: "BOK-1050440",
      source_url: "https://mybunchofkeys.com/property/belmont-classic-on-large-lot/",
      title: "Belmont Classic on large lot",
      slug: "belmont-classic-on-large-lot",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Industry Lane",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 79_500_000,
      description: "Classic house",
      image_url: "https://mybunchofkeys.com/wp-content/uploads/2020/01/broken-404.jpg",
      image_urls: [ "https://mybunchofkeys.com/wp-content/uploads/2020/01/broken-404.jpg" ],
      latitude: 10.6620,
      longitude: -61.5050
    )

    path = write_feed([ belmont_classic_row ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.removed
    assert_equal 0, result.updated
    assert_includes result.errors.join, "removed"
    assert_nil Property.find_by(id: existing.id)
  end

  test "soft-merges when title price beds baths sqft and images match" do
    imgs = good_row["images"]
    Property.create!(
      agent: @agent,
      bok_id: "BOK-100",
      source_url: "https://mybunchofkeys.com/property/soft-dup-old/",
      title: "Soft Dup Home",
      slug: "soft-dup-old-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Belmont",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "old",
      image_url: imgs.first,
      image_urls: imgs
    )

    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-200",
        "url" => "https://mybunchofkeys.com/property/soft-dup-new/",
        "title" => "Soft Dup Home - My Bunch of Keys",
        "bedrooms" => "3",
        "bathrooms" => "2",
        "sqft" => "2000sq.ft."
      )
    ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 0, result.created
    assert_equal 1, result.updated
    assert_nil Property.find_by(bok_id: "BOK-100")
    keeper = Property.find_by!(bok_id: "BOK-200")
    assert_equal "Soft Dup Home", keeper.title
    assert_equal 1_200_000_00, keeper.price_cents
  end

  test "does not soft-merge when galleries differ" do
    Property.create!(
      agent: @agent,
      bok_id: "BOK-300",
      source_url: "https://mybunchofkeys.com/property/soft-diff-img-old/",
      title: "Soft Diff Img Home",
      slug: "soft-diff-img-old-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Belmont",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 3,
      baths: 2,
      sqft: 2000,
      description: "old",
      image_url: "https://mybunchofkeys.com/wp-content/uploads/2024/01/other-1.jpg",
      image_urls: [
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/other-1.jpg",
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/other-2.jpg"
      ]
    )

    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-301",
        "url" => "https://mybunchofkeys.com/property/soft-diff-img-new/",
        "title" => "Soft Diff Img Home - My Bunch of Keys",
        "bedrooms" => "3",
        "bathrooms" => "2",
        "sqft" => "2000sq.ft."
      )
    ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    assert_equal 2, Property.where(title: "Soft Diff Img Home").count
  end

  test "does not soft-merge when beds baths or sqft differ" do
    imgs = good_row["images"]
    Property.create!(
      agent: @agent,
      bok_id: "BOK-400",
      source_url: "https://mybunchofkeys.com/property/soft-diff-beds-old/",
      title: "Soft Diff Beds Home",
      slug: "soft-diff-beds-old-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "Belmont",
      city: "Belmont",
      state: "Trinidad",
      zip: "",
      price_cents: 1_200_000_00,
      beds: 4,
      baths: 2,
      sqft: 2000,
      description: "old",
      image_url: imgs.first,
      image_urls: imgs
    )

    path = write_feed([
      good_row.merge(
        "bok_id" => "BOK-401",
        "url" => "https://mybunchofkeys.com/property/soft-diff-beds-new/",
        "title" => "Soft Diff Beds Home - My Bunch of Keys",
        "bedrooms" => "3",
        "bathrooms" => "2",
        "sqft" => "2000sq.ft."
      )
    ])
    result = BokListingsImporter.import!(path, agent: @agent)

    assert_equal 1, result.created
    assert_equal 2, Property.where(title: "Soft Diff Beds Home").count
  end

  test "dedupe_soft_duplicates keeps highest bok id" do
    imgs = good_row["images"]
    %w[BOK-10 BOK-50 BOK-30].each_with_index do |bok, i|
      Property.create!(
        agent: @agent,
        bok_id: bok,
        source_url: "https://mybunchofkeys.com/property/dedupe-#{i}/",
        title: "Dedupe Cluster",
        slug: "dedupe-cluster-#{i}-#{SecureRandom.hex(2)}",
        tag: "sale",
        property_type: "House",
        status: "active",
        address: "Belmont",
        city: "Belmont",
        state: "Trinidad",
        zip: "",
        price_cents: 900_000_00,
        beds: 2,
        baths: 1,
        sqft: 1100,
        description: "dup",
        image_url: imgs.first,
        image_urls: imgs
      )
    end

    summary = BokListingsImporter.dedupe_soft_duplicates!

    assert_equal 2, summary[:removed]
    assert_equal [ "BOK-50" ], Property.where(title: "Dedupe Cluster").pluck(:bok_id)
  end

  private

  def write_feed(rows)
    path = Rails.root.join("tmp/bok_importer_test_#{SecureRandom.hex(4)}.json")
    File.write(path, JSON.pretty_generate(rows))
    path
  end

  def belmont_classic_row
    {
      "url" => "https://mybunchofkeys.com/property/belmont-classic-on-large-lot/",
      "title" => "Belmont Classic on large lot - My Bunch of Keys",
      "price" => "$795,000",
      "bok_id" => "BOK-1050440",
      "location" => "Industry Lane, Belmont, Belmont",
      "bedrooms" => "4",
      "bathrooms" => "2",
      "sqft" => "4484sq.ft.",
      "image" => "",
      "images" => [],
      "description" => "Industry Lane classic house on a generous lot.",
      "features" => [ "Freehold Land" ]
    }
  end

  def good_row
    {
      "url" => "https://mybunchofkeys.com/property/archer-street-belmont/",
      "title" => "Archer Street Belmont Home - My Bunch of Keys",
      "price" => "$1,200,000",
      "bok_id" => "BOK-GOOD",
      "location" => "Archer Street, Belmont",
      "bedrooms" => "3",
      "bathrooms" => "2",
      "sqft" => "2000sq.ft.",
      "property_style" => "House",
      "property_type" => "For Sale",
      "image" => "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-1.jpg",
      "images" => [
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-1.jpg",
        "https://mybunchofkeys.com/wp-content/uploads/2024/01/archer-2.jpg"
      ],
      "description" => "Solid Belmont home with gallery photos.",
      "features" => [ "Gated Compound" ]
    }
  end
end
