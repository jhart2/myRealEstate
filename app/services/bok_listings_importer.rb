# Imports JSON produced by scripts/bok_gentle_listings_sync.py into Property records.
#
#   bin/rails bok:import[scripts/bok_sync_data/houses_last_month_….json]
#   bin/rails bok:import  # latest houses_last_month_*.json under scripts/bok_sync_data
#
class BokListingsImporter
  SITE_SUFFIX = /\s*[-–—]\s*My Bunch of Keys\s*\z/i
  DEFAULT_COORDS = [ 10.6549, -61.5019 ].freeze # Port of Spain centroid fallback

  # Theme/site chrome URLs that are not listing photos (mirrors bok_gentle_listings_sync.py).
  PLACEHOLDER_IMAGE_TOKENS = %w[
    /themes/
    share.jpg
    default.jpg
    default-halfpage-hero
    bok-icon.png
    logo.png
  ].freeze

  # Approximate community centroids for Trinidad map pins (not survey-grade).
  CITY_COORDS = {
    "maraval" => [ 10.7015, -61.5278 ],
    "port of spain" => [ 10.6549, -61.5019 ],
    "san fernando" => [ 10.2820, -61.4585 ],
    "chaguaramas" => [ 10.6885, -61.6382 ],
    "westmoorings" => [ 10.6755, -61.5585 ],
    "cascade" => [ 10.6850, -61.5120 ],
    "champs fleurs" => [ 10.6480, -61.4210 ],
    "diego martin" => [ 10.7205, -61.5580 ],
    "arima" => [ 10.6370, -61.2820 ],
    "tunapuna" => [ 10.6520, -61.3880 ],
    "st augustine" => [ 10.6410, -61.3990 ],
    "st. augustine" => [ 10.6410, -61.3990 ],
    "st joseph" => [ 10.6530, -61.4150 ],
    "st. joseph" => [ 10.6530, -61.4150 ],
    "curepe" => [ 10.6360, -61.4020 ],
    "san juan" => [ 10.6460, -61.4460 ],
    "barataria" => [ 10.6440, -61.4600 ],
    "woodbrook" => [ 10.6630, -61.5240 ],
    "st ann's" => [ 10.6850, -61.5150 ],
    "st anns" => [ 10.6850, -61.5150 ],
    "belmont" => [ 10.6620, -61.5050 ],
    "glencoe" => [ 10.6780, -61.5450 ],
    "goodwood park" => [ 10.6820, -61.5520 ],
    "valsayn" => [ 10.6300, -61.4100 ],
    "trincity" => [ 10.6350, -61.3500 ],
    "tobago" => [ 11.1800, -60.7400 ],
    "scarborough" => [ 11.1810, -60.7350 ],
    "couva" => [ 10.4220, -61.4670 ],
    "chaguanas" => [ 10.5160, -61.4110 ],
    "point fortin" => [ 10.1830, -61.6840 ],
    "princes town" => [ 10.2660, -61.3740 ],
    "sangre grande" => [ 10.5870, -61.1110 ],
    "mayaro" => [ 10.2910, -61.0060 ],
    "rio claro" => [ 10.3050, -61.1750 ],
    "freeport" => [ 10.4600, -61.4100 ],
    "carapichaima" => [ 10.4650, -61.4500 ],
    "santa cruz" => [ 10.7200, -61.4600 ],
    "maracas" => [ 10.7600, -61.4400 ],
    "las cuevas" => [ 10.7800, -61.4000 ],
    "petit valley" => [ 10.7000, -61.5500 ],
    "diamond vale" => [ 10.7050, -61.5650 ],
    "palmiste" => [ 10.2550, -61.4750 ],
    "gulf view" => [ 10.2550, -61.4550 ],
    "philipine" => [ 10.2650, -61.4600 ],
    "phillipine" => [ 10.2650, -61.4600 ],
    "tacarigua" => [ 10.6400, -61.3750 ],
    "orange grove" => [ 10.6400, -61.3700 ],
    "south oropouche" => [ 10.2050, -61.5300 ],
    "oropouche" => [ 10.2050, -61.5300 ],
    "la romain" => [ 10.2550, -61.4900 ],
    "endeavour" => [ 10.5250, -61.4050 ],
    "cunupia" => [ 10.5498, -61.3727 ],
    "chin chin" => [ 10.5535, -61.3706 ],
    "charlieville" => [ 10.5623, -61.4138 ],
    "carenage" => [ 10.6850, -61.5800 ],
    "cedros" => [ 10.0928, -61.8602 ],
    "blanchisseuse" => [ 10.7880, -61.3080 ],
    "longdenville" => [ 10.5142, -61.3786 ],
    "chase village" => [ 10.4719, -61.4142 ],
    "penal" => [ 10.1667, -61.4500 ],
    "gasparillo" => [ 10.3167, -61.4000 ],
    "toco" => [ 10.8333, -60.9500 ],
    "piarco" => [ 10.5950, -61.3400 ],
    "las lomas" => [ 10.5400, -61.3300 ]
  }.freeze

  Result = Struct.new(
    :created, :updated, :skipped, :removed, :errors,
    :copy_applied, :copy_flagged, :address_enriched,
    :touched_bok_ids, :created_bok_ids, :deduped,
    keyword_init: true
  )

  def self.import!(path = nil, agent: nil)
    new(path, agent: agent).import!
  end

  # Apply latest sale/rent + price rules to matching properties from a feed JSON
  # without re-running listing-copy / image / address upserts.
  def self.reconcile_offers!(path)
    new(path).reconcile_offers!
  end

  # Collapse soft-fingerprint rows, keeping the highest BOK id.
  def self.dedupe_soft_duplicates!
    new(skip_path: true).dedupe_soft_duplicates!
  end

  def initialize(path = nil, agent: nil, skip_path: false)
    @path = skip_path ? nil : resolve_path(path)
    @agent = agent
  end

  def import!
    rows = JSON.parse(File.read(@path))
    raise ArgumentError, "Expected a JSON array in #{@path}" unless rows.is_a?(Array)

    feed_agent = @agent || import_feed_agent
    result = Result.new(
      created: 0, updated: 0, skipped: 0, removed: 0, errors: [],
      copy_applied: 0, copy_flagged: 0, address_enriched: 0,
      touched_bok_ids: [], created_bok_ids: [], deduped: 0
    )
    touched_agent_ids = Set.new([ feed_agent.id ])
    total = rows.size
    cadence = BokSyncProgress.every
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    BokSyncProgress.say("import #{total} rows from #{File.basename(@path.to_s)}")

    rows.each_with_index do |row, index|
      agent = resolve_listing_agent(row, feed_agent)
      touched_agent_ids << agent.id
      import_row(row, agent, result)

      done = index + 1
      if done == total || (cadence.positive? && (done % cadence).zero?)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
        BokSyncProgress.say(
          "import #{done}/#{total} (#{elapsed}s) " \
          "created=#{result.created} updated=#{result.updated} skipped=#{result.skipped} " \
          "addr=#{result.address_enriched} copy=#{result.copy_applied} errors=#{result.errors.size}"
        )
      end
    end

    BokSyncProgress.say("import dedupe soft-fingerprint matches…")
    dup_summary = dedupe_soft_duplicates!
    result.deduped = dup_summary[:removed].to_i
    result.removed += result.deduped
    result.touched_bok_ids |= Array(dup_summary[:kept_bok_ids])
    BokSyncProgress.say("import deduped=#{result.deduped}") if result.deduped.positive?

    touched_agent_ids.each { |id| ::Agent.reset_counters(id, :properties) }
    result
  end

  # Soft duplicates: same title + price + beds + baths + sqft + image set.
  # Differing beds/baths/sqft (nil vs present) or different galleries are NOT dups.
  def dedupe_soft_duplicates!
    removed = 0
    kept = []
    errors = []

    fingerprint_groups.each do |_fp, props|
      next if props.size <= 1

      ordered = props.sort_by { |p| [ -bok_id_rank(p.bok_id), -p.id ] }
      keeper = ordered.first
      losers = ordered.drop(1)
      losers.each do |dup|
        dup.destroy!
        removed += 1
      rescue StandardError => e
        errors << "#{dup.bok_id || dup.id}: #{e.class}: #{e.message}"
      end
      kept << keeper.bok_id if keeper.bok_id.present?
    end

    { removed: removed, kept_bok_ids: kept.compact.uniq, errors: errors }
  end

  # Re-apply resolve_offer rules to feed rows that already exist locally.
  # Fixes dual sale/rent tip-price + tag drift without a full re-upsert.
  def reconcile_offers!
    rows = JSON.parse(File.read(@path))
    raise ArgumentError, "Expected a JSON array in #{@path}" unless rows.is_a?(Array)

    updated = 0
    skipped = 0
    missing = 0
    errors = []
    touched = []
    total = rows.size
    cadence = BokSyncProgress.every
    BokSyncProgress.say("offer reconcile #{total} feed rows")

    rows.each_with_index do |row, index|
      bok_id = row["bok_id"].to_s.strip.presence
      next if bok_id.blank?

      property = Property.find_by(bok_id: bok_id)
      unless property
        missing += 1
        next
      end

      offer = resolve_offer(row)
      price_cents = offer[:price_cents]
      tag = offer[:tag]
      if price_cents.nil? || price_cents <= 0 || tag.blank?
        skipped += 1
        next
      end

      property.assign_attributes(tag: tag, price_cents: price_cents)
      if property.changed?
        property.save!
        updated += 1
        touched << bok_id
      else
        skipped += 1
      end
    rescue StandardError => e
      errors << "#{bok_id}: #{e.class}: #{e.message}"
    ensure
      done = index + 1
      if done == total || (cadence.positive? && (done % cadence).zero?)
        BokSyncProgress.say(
          "offer reconcile #{done}/#{total} updated=#{updated} skipped=#{skipped} missing=#{missing}"
        )
      end
    end

    {
      path: @path.to_s,
      updated: updated,
      skipped: skipped,
      missing: missing,
      errors: errors,
      touched_bok_ids: touched
    }
  end

  private

  def resolve_path(path)
    return Pathname.new(path) if path.present?

    packaged = Rails.root.join("db/data/bok_listings.json")
    return packaged if packaged.exist?

    dir = Rails.root.join("scripts/bok_sync_data")
    latest = Dir.glob(dir.join("houses_last_month_*.json")).max_by { |f| File.mtime(f) }
    raise ArgumentError, "No db/data/bok_listings.json or houses_last_month_*.json under #{dir}" unless latest

    Pathname.new(latest)
  end

  # Feed-level agent retained as fallback when a row has no listing agent,
  # and as the explicit association when callers pass `agent:`.
  def import_feed_agent
    ::Agent.find_or_create_by!(email: "import@mybunchofkeys.com") do |a|
      a.name = "My Bunch of Keys"
      a.title = "Listing Feed"
      a.bio = "Listings synced from mybunchofkeys.com"
      a.phone = ""
      a.active = true
      a.show_on_homepage = false
      a.listings_count = 0
    end
  end

  def resolve_listing_agent(row, feed_agent)
    name = row["agent"].to_s.strip
    return feed_agent if name.blank?

    phone = row["agent_phone"].to_s.strip
    agency = row["agent_agency"].to_s.strip.presence || "Listing Agent"
    image = row["agent_image"].to_s.strip.presence
    email = import_email_for(name)

    agent = ::Agent.find_by(email: email)
    agent ||= ::Agent.find_by("LOWER(name) = ? AND phone = ?", name.downcase, phone) if phone.present?
    agent ||= ::Agent.find_by("LOWER(name) = ?", name.downcase)

    if agent
      updates = {}
      updates[:name] = name if agent.name != name
      updates[:title] = agency if agent.title != agency
      updates[:phone] = phone if phone.present? && agent.phone != phone
      updates[:image_url] = image if image.present? && agent.image_url != image
      agent.update!(updates) if updates.any?
      agent
    else
      ::Agent.create!(
        name: name,
        title: agency,
        email: email,
        phone: phone,
        image_url: image,
        bio: "Imported listing agent from mybunchofkeys.com",
        active: true,
        show_on_homepage: false,
        listings_count: 0
      )
    end
  end

  def import_email_for(name)
    slug = name.to_s.parameterize.presence || "agent"
    "#{slug}@import.mybunchofkeys.com"
  end

  def import_row(row, agent, result)
    bok_id = row["bok_id"].to_s.strip.presence
    source_url = row["url"].to_s.strip.presence
    if bok_id.blank? && source_url.blank?
      result.skipped += 1
      return
    end

    offer = resolve_offer(row)
    price_cents = offer[:price_cents]
    if price_cents.nil? || price_cents <= 0
      result.skipped += 1
      result.errors << "#{bok_id || source_url}: missing/invalid price"
      return
    end

    image_urls = resolve_image_urls(row)
    if image_urls.empty?
      property = find_property(bok_id, source_url)
      handle_unusable_images!(property, bok_id || source_url, result)
      return
    end

    beds = row["bedrooms"].to_s[/\d+/]&.to_i
    baths = parse_baths(row["bathrooms"])
    sqft = parse_sqft(row["sqft"])
    title = clean_title(row["title"], row["url"])
    fingerprint = soft_fingerprint(
      title:, price_cents:, beds:, baths:, sqft:, image_urls:
    )
    property = find_property(bok_id, source_url, fingerprint: fingerprint)

    attrs = build_attrs(
      row, agent, price_cents, image_urls,
      result: result, existing: property, tag: offer[:tag]
    )
    attrs = protect_description_from_truncation!(attrs, property, result, label: bok_id || source_url)
    attrs = prefer_newer_identity(attrs, property, bok_id, source_url)

    if property
      property.assign_attributes(attrs.except(:slug))
      if property.changed?
        property.save!
        result.updated += 1
        result.touched_bok_ids << property.bok_id if property.bok_id.present?
        apply_listing_copy!(property, result)
        enqueue_gallery_ingest!(property)
      else
        result.skipped += 1
        enqueue_gallery_ingest!(property)
      end
    else
      property = Property.create!(attrs)
      result.created += 1
      if property.bok_id.present?
        result.touched_bok_ids << property.bok_id
        result.created_bok_ids << property.bok_id
      end
      apply_listing_copy!(property, result)
      enqueue_gallery_ingest!(property)
    end
  rescue ActiveRecord::RecordInvalid => e
    result.errors << "#{bok_id || source_url}: #{e.record.errors.full_messages.to_sentence}"
    result.skipped += 1
  end

  # Fire-and-forget gallery_ingest job (host originals). Never blocks listing publish/save.
  def enqueue_gallery_ingest!(property)
    return unless property&.persisted?

    property.enqueue_gallery_ingest!
  end

  # Dual sale/rent pages often scrape the monthly USD tip price as "For Sale".
  # Prefer an explicit purchase price from the body and keep tag=sale for duals.
  PURCHASE_FLOOR_CENTS = 100_000_00 # TT$100k

  def resolve_offer(row)
    scraped = row["price"].to_s
    title = row["title"].to_s
    url = row["url"].to_s
    desc = row["description"].to_s
    blob = [ title, url, desc ].join("\n")

    sale_cents = extract_sale_price_cents(blob)
    rent_cents = extract_rent_price_cents(blob)
    scraped_cents = parse_price_cents(scraped)
    scraped_monthly = monthly_price_label?(scraped)
    dual = dual_offer_text?(blob) || (sale_cents.present? && rent_cents.present?)

    if scraped_monthly && sale_cents
      return { tag: "sale", price_cents: sale_cents }
    end

    if scraped_cents && scraped_cents < PURCHASE_FLOOR_CENTS && rentish_dwelling?(row) &&
        (scraped_monthly || sale_cents.nil?)
      return { tag: "rent", price_cents: scraped_cents }
    end

    if dual
      purchase = sale_cents
      purchase ||= scraped_cents if scraped_cents && scraped_cents >= PURCHASE_FLOOR_CENTS && !scraped_monthly
      if purchase
        return { tag: "sale", price_cents: purchase }
      end

      monthly = rent_cents || scraped_cents
      return { tag: "rent", price_cents: monthly } if monthly
    end

    tag = map_tag(
      row,
      sale_cents: sale_cents,
      rent_cents: rent_cents,
      scraped_cents: scraped_cents,
      dual: dual
    )
    price =
      if tag == "sale"
        sale_cents || scraped_cents
      else
        rent_cents || scraped_cents
      end
    { tag: tag, price_cents: price }
  end

  def dual_offer_text?(blob)
    blob.to_s.downcase.match?(
      /for\s+sale\s*\/\s*or\s*\/?\s*rent|for\s+rent\s*\/\s*sale|sale\s*\/?\s*or\s*\/?\s*rent|
       sale-or-rent|for-sale-rent|rent\s+or\s+sale|sale\s+or\s+rent|for\s+sale\s*\/\s*rent|
       for\s+rent\s*\/\s*or\s*\/?\s*sale/x
    )
  end

  def rentish_dwelling?(row)
    style = row["property_style"].to_s
    title = row["title"].to_s
    style.match?(/apartment|townhouse/i) ||
      title.match?(/apartment|townhouse|condo|penthouse|house|home/i)
  end

  def monthly_price_label?(raw)
    text = raw.to_s.downcase
    return true if text.match?(/\/\s*mth|\/\s*mo\b|per\s+month|\/\s*month/)

    digits = text.gsub(/[^\d]/, "").to_i
    text.include?("(usd)") && digits.between?(500, 20_000)
  end

  def extract_sale_price_cents(blob)
    text = blob.to_s
    patterns = [
      /for\s+sale[^$\d]{0,40}(?:tt\$|\$)?\s*([\d.,]+)\s*(m\b|mil(?:lion)?|mm)?/i,
      /sale\s*(?:price)?\s*[:=\-–]?\s*(?:tt\$|\$)?\s*([\d.,]+)\s*(m\b|mil(?:lion)?|mm)?/i
    ]
    amounts = patterns.flat_map { |re| text.scan(re) }.filter_map do |num, mag|
      to_price_cents(num, magnitude: mag)
    end
    amounts.select { |c| c >= PURCHASE_FLOOR_CENTS }.max
  end

  def extract_rent_price_cents(blob)
    text = blob.to_s
    patterns = [
      /for\s+rent[^$\d]{0,40}(?:us\$|usd|tt\$|\$)?\s*([\d.,]+)/i,
      /rent(?:al)?(?:\s+options?)?\s*[:=\-–]?\s*(?:us\$|usd|tt\$|\$)?\s*([\d.,]+)/i,
      /(?:us\$|usd|tt\$|\$)\s*([\d.,]+)\s*(?:\/\s*mth|\/\s*mo\b|per\s+month|\/\s*month)/i
    ]
    amounts = patterns.flat_map { |re| text.scan(re) }.filter_map do |match|
      num = match.is_a?(Array) ? match[0] : match
      cents = to_price_cents(num)
      cents && cents < PURCHASE_FLOOR_CENTS ? cents : nil
    end
    amounts.max
  end

  def to_price_cents(num, magnitude: nil)
    digits = num.to_s.gsub(/[^\d.]/, "")
    return nil if digits.blank?

    value = BigDecimal(digits)
    mag = magnitude.to_s.downcase
    value *= 1_000_000 if mag.start_with?("m")
    (value * 100).to_i
  rescue ArgumentError
    nil
  end

  def polished_rich_description?(property)
    html = property.respond_to?(:description_html) ? property.description_html.to_s : ""
    return false if html.blank?
    return true if html.match?(/<h2\b/i) &&
      ListingDescriptionRichFormatter::BESPOKE_HEADING_LABELS.any? { |label|
        html.include?(label) || html.include?(ERB::Util.html_escape(label))
      }

    false
  end

  # Keep polished HTML / good bodies, but never lock in (or accept) truncated scrape copy.
  def protect_description_from_truncation!(attrs, property, result, label:)
    incoming = attrs[:description].to_s
    incoming_truncated = TruncatedDescription.suspect?(incoming)
    existing_truncated = property && TruncatedDescription.suspect_property?(property)
    polished = property && polished_rich_description?(property)

    if incoming_truncated && property && !existing_truncated
      result.errors << "#{label}: skipped truncated BOK description (kept existing)"
      return attrs.except(:description)
    end

    if incoming_truncated && property.nil?
      result.errors << "#{label}: imported description looks truncated (ends with … or ~1200 mid-cut)"
    end

    # Polished rich HTML wins unless the site copy itself is still truncated — then
    # allow a fuller scrape through so repair / sync can heal it.
    if polished && !existing_truncated
      attrs.except(:description)
    elsif polished && existing_truncated && !incoming_truncated && TruncatedDescription.better_replacement?(TruncatedDescription.plain_for(property), incoming)
      attrs
    elsif polished && existing_truncated && incoming_truncated
      attrs.except(:description)
    else
      attrs
    end
  end

  # After create/update: OpenAI clean → apply if clean, else flag.
  # Never rewrite after a successful apply (status=ok) or polished rich HTML.
  # Safe rematches are a separate dry daisy (listing_copy:daisy), not inline here.
  def apply_listing_copy!(property, result)
    return unless listing_copy_enabled?
    return if listing_copy_locked?(property)

    outcome = ListingCopyApplier.call(property)
    if outcome.applied?
      result.copy_applied += 1
    else
      result.copy_flagged += 1
    end
  rescue OpenaiClient::Error, ListingCopyCleaner::Error, ListingCopyApplier::Error => e
    result.copy_flagged += 1
    result.errors << "#{property.bok_id || property.id}: listing copy #{e.message}"
  end

  def listing_copy_locked?(property)
    polished_rich_description?(property) || listing_copy_applied_ok?(property)
  end

  def listing_copy_applied_ok?(property)
    notes = property.respond_to?(:copy_review_notes) ? property.copy_review_notes : nil
    notes.is_a?(Hash) && notes["status"].to_s == "ok"
  end

  def listing_copy_enabled?
    return false if ENV["BOK_APPLY_LISTING_COPY"].to_s == "0"
    return true if ENV["BOK_APPLY_LISTING_COPY"].to_s == "1"
    return false if Rails.env.test?

    OpenaiClient.new.configured?
  end

  # Feed rows with no real listing photos must not stay public.
  # Existing rows are destroyed when they fall off the feed.
  # Status is preserved on update so admin Disabled/Sold/etc. survives sync.
  def handle_unusable_images!(property, label, result)
    if property
      property.destroy!
      result.removed += 1
      result.errors << "#{label}: no usable images (removed)"
    else
      result.skipped += 1
      result.errors << "#{label}: no usable images"
    end
  end

  def resolve_image_urls(row)
    normalize_image_urls(row["images"].presence || row["image"])
  end

  def find_property(bok_id, source_url, fingerprint: nil)
    scope = Property.all
    by_bok = bok_id.present? ? scope.find_by(bok_id: bok_id) : nil
    return by_bok if by_bok

    by_url = source_url.present? ? scope.find_by(source_url: source_url) : nil
    return by_url if by_url

    find_soft_duplicate(fingerprint)
  end

  def soft_fingerprint(title:, price_cents:, beds:, baths:, sqft:, image_urls:)
    images = images_fingerprint(image_urls)
    {
      title: title.to_s.strip.downcase,
      price_cents: price_cents.to_i,
      beds: beds.nil? ? nil : beds.to_i,
      baths: baths.nil? ? nil : BigDecimal(baths.to_s),
      sqft: sqft.nil? ? nil : sqft.to_i,
      images: images
    }
  end

  # Canonical gallery identity: order-insensitive normalized URL set.
  def images_fingerprint(urls)
    normalize_image_urls(urls)
      .map { |url| url.to_s.strip.downcase.sub(/\?.*\z/, "").delete_suffix("/") }
      .reject(&:blank?)
      .uniq
      .sort
  end

  def find_soft_duplicate(fingerprint)
    return nil if fingerprint.blank? || fingerprint[:title].blank? || fingerprint[:price_cents].to_i <= 0
    return nil if fingerprint[:images].blank?

    scope = Property.where("LOWER(TRIM(title)) = ?", fingerprint[:title])
      .where(price_cents: fingerprint[:price_cents])
    scope = fingerprint[:beds].nil? ? scope.where(beds: nil) : scope.where(beds: fingerprint[:beds])
    scope = fingerprint[:baths].nil? ? scope.where(baths: nil) : scope.where(baths: fingerprint[:baths])
    scope = fingerprint[:sqft].nil? ? scope.where(sqft: nil) : scope.where(sqft: fingerprint[:sqft])

    scope.select { |p| images_fingerprint(p.image_urls) == fingerprint[:images] }
      .max_by { |p| [ bok_id_rank(p.bok_id), p.id ] }
  end

  def fingerprint_groups
    Property.where.not(title: [ nil, "" ]).where("price_cents > 0").find_each
      .group_by { |p|
        soft_fingerprint(
          title: p.title,
          price_cents: p.price_cents,
          beds: p.beds,
          baths: p.baths,
          sqft: p.sqft,
          image_urls: p.image_urls
        )
      }
      .select { |fp, props| props.size > 1 && fp[:images].present? }
  end

  def bok_id_rank(bok_id)
    bok_id.to_s[/\d+/].to_i
  end

  # Soft-matched older scrape keeps the newer BOK identity when ranks differ.
  def prefer_newer_identity(attrs, existing, incoming_bok_id, _incoming_url)
    return attrs unless existing

    if bok_id_rank(incoming_bok_id) < bok_id_rank(existing.bok_id)
      attrs = attrs.merge(bok_id: existing.bok_id)
      attrs = attrs.merge(source_url: existing.source_url) if existing.source_url.present?
    elsif bok_id_rank(incoming_bok_id) == bok_id_rank(existing.bok_id) &&
          incoming_bok_id.present? && existing.bok_id.present? &&
          incoming_bok_id != existing.bok_id
      attrs = attrs.merge(bok_id: existing.bok_id, source_url: existing.source_url)
    end
    attrs
  end

  def build_attrs(row, agent, price_cents, image_urls, result: nil, existing: nil, tag: nil)
    title = clean_title(row["title"], row["url"])
    # Never re-reconcile addresses on updates — AI/Google run once on create only.
    address_attrs = if existing
      existing_address_attrs(existing)
    else
      place = ListingAddressBrain.enrich(row.merge("title" => title))
      if result && place.source.to_s.match?(/openai|google/)
        result.address_enriched += 1
      end
      merge_address_attrs(nil, place)
    end
    primary = normalize_image_urls(row["image"]).first || image_urls.first

    {
      agent: agent,
      bok_id: row["bok_id"].presence,
      source_url: row["url"].presence,
      title: title,
      slug: slug_for(row),
      tag: tag.presence || map_tag(row),
      property_type: map_property_type(row),
      status: existing&.status.presence || "active",
      address: address_attrs[:address],
      city: address_attrs[:city],
      state: address_attrs[:state],
      zip: address_attrs[:zip],
      location_raw: BokLocationToolkit.sanitize(row["location"]),
      price_cents: price_cents,
      beds: row["bedrooms"].to_s[/\d+/]&.to_i,
      baths: parse_baths(row["bathrooms"]),
      sqft: parse_sqft(row["sqft"]),
      description: row["description"].to_s.strip.presence || title,
      image_url: primary,
      latitude: address_attrs[:latitude],
      longitude: address_attrs[:longitude],
      featured: false,
      features: normalize_features(row["features"]),
      image_urls: image_urls
    }.tap do |attrs|
      lot = LotSizeExtractor.call([ title, attrs[:description] ].join("\n"))
      if lot
        attrs[:acres] = lot.acres
        attrs[:lot_sqft] = lot.lot_sqft
      end
    end
  end

  def existing_address_attrs(property)
    {
      address: property.address,
      city: property.city,
      state: property.state,
      zip: property.zip.to_s,
      latitude: property.latitude,
      longitude: property.longitude
    }
  end

  # Never demote a stronger existing street line during sync updates.
  def merge_address_attrs(existing, place)
    proposed = {
      address: place.address.to_s,
      city: place.city.to_s,
      state: place.state.to_s,
      zip: place.zip.to_s,
      latitude: place.latitude,
      longitude: place.longitude
    }
    return proposed unless existing

    before_q = BokAddressResolver.address_quality(existing.address, existing.city)
    after_q = BokAddressResolver.address_quality(proposed[:address], proposed[:city])

    if after_q < before_q || (before_q >= 3 && existing.address.to_s.match?(/\d/) && !proposed[:address].match?(/\d/))
      lat, lng = prefer_street_coords(existing, proposed)
      return {
        address: existing.address,
        city: existing.city,
        state: existing.state,
        zip: existing.zip.to_s,
        latitude: lat,
        longitude: lng
      }
    end

    island_blob = "#{existing.title} #{existing.source_url} #{existing.city}".downcase
    if proposed[:state] == "Tobago" && existing.state.to_s != "Tobago" &&
       !(island_blob.match?(/\btobago\b/) && !island_blob.match?(/trinidad\s+and\s+tobago/))
      proposed[:state] = existing.state
    end

    lat, lng = prefer_street_coords(existing, proposed)
    proposed.merge(latitude: lat, longitude: lng)
  end

  # Keep a refined street pin if the proposal is still a city-centroid dump.
  def prefer_street_coords(existing, proposed)
    existing_city = PropertyStreetGeocoder.city_level_coords?(existing.latitude, existing.longitude)
    proposed_city = PropertyStreetGeocoder.city_level_coords?(proposed[:latitude], proposed[:longitude])

    if !existing_city && (proposed[:latitude].blank? || proposed_city)
      return [ existing.latitude, existing.longitude ]
    end

    [
      proposed[:latitude].presence || existing.latitude,
      proposed[:longitude].presence || existing.longitude
    ]
  end

  def map_tag(row, sale_cents: nil, rent_cents: nil, scraped_cents: nil, dual: nil)
    intent = row["property_type"].to_s.downcase
    price = row["price"].to_s.downcase
    url = row["url"].to_s.downcase
    title = row["title"].to_s.downcase
    desc = row["description"].to_s.downcase
    blob = "#{title}\n#{url}\n#{desc}"
    dual = dual.nil? ? dual_offer_text?(blob) : dual
    scraped_cents ||= parse_price_cents(row["price"])
    purchase_like = (sale_cents && sale_cents >= PURCHASE_FLOOR_CENTS) ||
      (scraped_cents && scraped_cents >= PURCHASE_FLOOR_CENTS && !monthly_price_label?(row["price"]))

    # Dual listing with a purchase price stays sale (don't flip from title "for rent").
    return "sale" if dual && purchase_like

    # Explicit rent intent without a dual/sale conflict.
    return "rent" if intent.include?("rent") && !intent.include?("sale") && !dual
    return "rent" if monthly_price_label?(price) && !purchase_like
    return "rent" if (url.include?("for-rent") || title.include?("for rent")) && !purchase_like && !dual

    return "sale" if intent.include?("sale") || intent.include?("buy") || purchase_like

    "sale"
  end

  def map_property_type(row)
    style = row["property_style"].to_s.strip
    blob = "#{row['title']} #{row['description']} #{row['url']}".downcase

    case style
    when "House"
      return "Villa" if blob.include?("villa")
      return "Penthouse" if blob.include?("penthouse")
      return "Modern Home" if blob.include?("modern home")
      "House"
    when "Apartment/Townhouse"
      return "Townhouse" if blob.include?("townhouse") || blob.include?("town house") || blob.include?("town-house")
      "Apartment"
    when "Land"
      "Land"
    when "Commercial"
      "Commercial"
    when "Villa"
      "Villa"
    when "Penthouse"
      "Penthouse"
    else
      return "Townhouse" if blob.include?("townhouse")
      return "Apartment" if blob.include?("apartment")
      return "Land" if blob.match?(/\bland\b|\bacre/)
      return "Commercial" if blob.match?(/commercial|office|warehouse|retail|storage/)
      return "Villa" if blob.include?("villa")
      return "Penthouse" if blob.include?("penthouse")
      "House"
    end
  end

  def clean_title(raw, url)
    title = unescape(raw.to_s).gsub(SITE_SUFFIX, "").strip
    return title if title.present?

    path = URI.parse(url.to_s).path.to_s
    path.split("/").reject(&:blank?).last.to_s.tr("-", " ").titleize.presence || "BOK listing"
  rescue URI::InvalidURIError
    "BOK listing"
  end

  def address_from(title, city)
    BokAddressResolver.call("title" => title, "location" => city).address
  end

  def slug_for(row)
    from_url = row["url"].to_s[%r{/property/([^/]+)/?}i, 1]
    base = (from_url.presence || row["bok_id"].presence || row["title"]).to_s.parameterize
    base = "bok-listing" if base.blank?
    candidate = base
    n = 2
    while Property.exists?(slug: candidate)
      existing = Property.find_by(slug: candidate)
      break if existing && (existing.bok_id == row["bok_id"] || existing.source_url == row["url"])

      candidate = "#{base}-#{n}"
      n += 1
    end
    candidate
  end

  def parse_price_cents(raw)
    digits = raw.to_s.gsub(/[^\d.]/, "")
    return nil if digits.blank?

    (BigDecimal(digits) * 100).to_i
  end

  def parse_baths(raw)
    text = raw.to_s.strip
    return nil if text.blank?

    if (match = text.match(/(\d+)\s*(?:and\s+a\s+half|\.5|1\/2)/i))
      return match[1].to_i + 0.5
    end

    match = text.match(/(\d+(?:\.\d+)?)/)
    return nil unless match

    number = Float(match[1])
    number == number.to_i ? number.to_i : number
  rescue ArgumentError, TypeError
    nil
  end

  def parse_sqft(raw)
    digits = raw.to_s.gsub(/[^\d]/, "")
    digits.present? ? digits.to_i : nil
  end

  def coords_for(city)
    key = city.to_s.downcase.strip
    return CITY_COORDS[key] if CITY_COORDS.key?(key)

    match = CITY_COORDS.find { |name, _| key.include?(name) || name.include?(key) }
    match ? match.last : DEFAULT_COORDS
  end

  def unescape(text)
    CGI.unescapeHTML(text.to_s)
  end

  def normalize_features(raw)
    Array(raw).flat_map { |item| item.is_a?(String) ? item.split(/\s*;\s*/) : item }
      .map { |item| item.to_s.strip }
      .reject(&:blank?)
      .uniq
  end

  def normalize_image_urls(raw)
    Array(raw).flat_map { |item| item.is_a?(String) ? item.split(/\s*;\s*/) : item }
      .map { |item| Property.normalize_gallery_url(item) }
      .reject(&:blank?)
      .reject { |url| placeholder_image?(url) }
      .uniq
  end

  def placeholder_image?(url)
    lower = url.to_s.downcase
    PLACEHOLDER_IMAGE_TOKENS.any? { |token| lower.include?(token) }
  end
end
