# Finds strong near-duplicate listing pairs and (optionally) flags them.
#
# A pair is "strong" when ≥3 of these signals match:
#   - title   similar after normalize (token Jaccard ≥ 0.72 or equal)
#   - price   equal or within 2% (min $1k slack)
#   - location same city + (similar address OR coords within ~75m)
#   - features overlapping (Jaccard ≥ 0.5 when both non-empty)
#
# Usage:
#   PropertyDuplicateDetector.call(dry_run: true)
#   PropertyDuplicateDetector.call(dry_run: false)
class PropertyDuplicateDetector
  TITLE_JACCARD = 0.72
  FEATURE_JACCARD = 0.5
  PRICE_RELATIVE = 0.02
  PRICE_ABS_CENTS = 100_000 # $1,000
  COORD_DELTA = 0.0007 # ~75m
  MIN_SIGNALS = 3

  STOPWORDS = %w[
    for sale rent listing home house apartment villa townhouse land lot
    the a an and or in at on of to with from by
  ].freeze

  Result = Struct.new(
    :dry_run, :scanned, :pair_count, :flagged_ids, :pairs, :applied,
    keyword_init: true
  )

  Pair = Struct.new(
    :left_id, :right_id, :left_slug, :right_slug, :signals, :score,
    keyword_init: true
  )

  def self.call(scope: Property.active, dry_run: true, limit_pairs: 50)
    new(scope: scope, dry_run: dry_run, limit_pairs: limit_pairs).call
  end

  def initialize(scope:, dry_run:, limit_pairs:)
    @scope = scope
    @dry_run = dry_run
    @limit_pairs = limit_pairs
  end

  def call
    rows = load_rows
    pairs = find_pairs(rows)
    flagged_ids = pairs.flat_map { |p| [ p.left_id, p.right_id ] }.uniq.sort

    applied = false
    unless @dry_run
      apply_flags!(flagged_ids)
      applied = true
    end

    Result.new(
      dry_run: @dry_run,
      scanned: rows.size,
      pair_count: pairs.size,
      flagged_ids: flagged_ids,
      pairs: pairs.first(@limit_pairs),
      applied: applied
    )
  end

  private

  def load_rows
    @scope
      .select(:id, :slug, :title, :price_cents, :address, :city, :latitude, :longitude, :features, :tag)
      .map { |p| serialize(p) }
  end

  def serialize(property)
    city = property.city.to_s.strip.downcase
    {
      id: property.id,
      slug: property.slug,
      title_tokens: tokenize(property.title),
      title_key: normalize_key(property.title),
      price_cents: property.price_cents.to_i,
      address_tokens: tokenize(property.address),
      address_key: normalize_key(property.address),
      city: city,
      lat: property.latitude&.to_f,
      lng: property.longitude&.to_f,
      features: Array(property.features).map { |f| f.to_s.strip.downcase }.reject(&:blank?).uniq,
      tag: property.tag.to_s
    }
  end

  def find_pairs(rows)
    pairs = []
    rows.group_by { |r| r[:city] }.each_value do |bucket|
      next if bucket.size < 2

      bucket.combination(2) do |left, right|
        # Different sale/rent markets are rarely true dups.
        next if left[:tag].present? && right[:tag].present? && left[:tag] != right[:tag]

        signals = matched_signals(left, right)
        next if signals.size < MIN_SIGNALS

        pairs << Pair.new(
          left_id: left[:id],
          right_id: right[:id],
          left_slug: left[:slug],
          right_slug: right[:slug],
          signals: signals,
          score: signals.size
        )
      end
    end
    pairs.sort_by { |p| [ -p.score, p.left_id, p.right_id ] }
  end

  def matched_signals(left, right)
    signals = []
    signals << "title" if title_match?(left, right)
    signals << "price" if price_match?(left, right)
    signals << "location" if location_match?(left, right)
    signals << "features" if features_match?(left, right)
    signals
  end

  def title_match?(left, right)
    return true if left[:title_key].present? && left[:title_key] == right[:title_key]

    jaccard(left[:title_tokens], right[:title_tokens]) >= TITLE_JACCARD
  end

  def price_match?(left, right)
    a = left[:price_cents]
    b = right[:price_cents]
    return false if a <= 0 || b <= 0
    return true if a == b

    slack = [ (a * PRICE_RELATIVE).round, PRICE_ABS_CENTS ].max
    (a - b).abs <= slack
  end

  def location_match?(left, right)
    return false if left[:city].blank? || left[:city] != right[:city]

    if left[:address_key].present? && left[:address_key] == right[:address_key]
      return true
    end

    if jaccard(left[:address_tokens], right[:address_tokens]) >= 0.6
      return true
    end

    coords_close?(left, right)
  end

  def features_match?(left, right)
    return false if left[:features].empty? || right[:features].empty?

    jaccard(left[:features], right[:features]) >= FEATURE_JACCARD
  end

  def coords_close?(left, right)
    return false unless left[:lat] && left[:lng] && right[:lat] && right[:lng]

    (left[:lat] - right[:lat]).abs <= COORD_DELTA &&
      (left[:lng] - right[:lng]).abs <= COORD_DELTA
  end

  def apply_flags!(flagged_ids)
    Property.where(possible_duplicate: true).where.not(id: flagged_ids).update_all(possible_duplicate: false)
    Property.where(id: flagged_ids).update_all(possible_duplicate: true) if flagged_ids.any?
  end

  def tokenize(text)
    normalize_key(text).split.reject { |w| STOPWORDS.include?(w) }.uniq
  end

  def normalize_key(text)
    text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").gsub(/\s+/, " ").strip
  end

  def jaccard(a, b)
    sa = Array(a)
    sb = Array(b)
    return 0.0 if sa.empty? || sb.empty?

    inter = (sa & sb).size
    union = (sa | sb).size
    return 0.0 if union.zero?

    inter.to_f / union
  end
end
