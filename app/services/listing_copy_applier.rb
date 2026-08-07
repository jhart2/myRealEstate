# OpenAI path: clean once → apply if verification is clean, else flag with preview.
# Safe rematches never run inside the OpenAI call — they are separate dry steps:
#
#   ListingCopyApplier.call(property)                    # OpenAI: apply or flag
#   ListingCopyApplier.daisy_chain_safe_flags!           # dry daisy chain
#   ListingCopyApplier.reprocess_policy!(policy: "…")    # one dry link
#
class ListingCopyApplier
  class Error < StandardError; end

  SIZE_FIELDS = %w[sqft lot_sqft acres].freeze
  BLOCKING_FIELDS = %w[beds baths property_type tag address city title description].freeze

  # Ordered dry daisy-chain links (no OpenAI).
  SAFE_POLICY_ORDER = %w[
    safe_size_rematch
    safe_half_bath_rematch
    safe_size_and_half_bath_rematch
    safe_size_and_nil_fill_specs_rematch
    safe_type_rematch
    safe_sparse_copy_rematch
  ].freeze

  Result = Struct.new(
    :property, :cleaner_result, :applied, :skipped, :error,
    keyword_init: true
  ) do
    def applied? = applied
    def skipped? = skipped
  end

  APPLY_KEYS = %w[
    title address city state zip description
    beds baths sqft lot_sqft acres
    property_type tag features
  ].freeze

  TYPE_TITLE_PATTERNS = {
    "Land" => /\b(?:land\s+for\s+sale|agriculture(?:al)?\s+land|vacant\s+land|\bland\b)/i,
    "Commercial" => /\bcommercial\b/i,
    "Townhouse" => /\btownhouses?\b|\btownhomes?\b/i,
    "Apartment" => /\bapartments?\b|\bcondo(?:minium)?s?\b|\bapartment\s+buildings?\b/i,
    "Penthouse" => /\bpenthouses?\b/i,
    "Villa" => /\bvillas?\b/i,
    "House" => /\bhouses?\b|\bfamily\s+home\b|\bsingle[-\s]family\b/i,
    "Modern Home" => /\bmodern\s+homes?\b/i
  }.freeze

  def self.call(property, client: OpenaiClient.new)
    new(property, client: client).call
  end

  # Run each safe policy as its own dry pass over the current flagged queue.
  def self.daisy_chain_safe_flags!(scope = Property.copy_needs_review)
    ids = scope.pluck(:id)
    steps = {}
    SAFE_POLICY_ORDER.each do |policy|
      stats = reprocess_policy!(Property.copy_needs_review.where(id: ids), policy: policy)
      steps[policy] = stats
    end
    {
      steps: steps,
      applied: steps.values.sum { |s| s[:applied].to_i },
      remaining: Property.copy_needs_review.where(id: ids).count
    }
  end

  # Back-compat alias → full dry daisy chain.
  def self.reprocess_safe_flags!(scope = Property.copy_needs_review)
    daisy_chain_safe_flags!(scope)
  end

  def self.reprocess_safe_size_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_size_rematch")
  end

  def self.reprocess_safe_half_bath_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_half_bath_rematch")
  end

  def self.reprocess_safe_combo_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_size_and_half_bath_rematch")
  end

  def self.reprocess_safe_nil_fill_specs_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_size_and_nil_fill_specs_rematch")
  end

  def self.reprocess_safe_type_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_type_rematch")
  end

  def self.reprocess_safe_sparse_flags!(scope = Property.copy_needs_review)
    reprocess_policy!(scope, policy: "safe_sparse_copy_rematch")
  end

  def self.reprocess_policy!(scope = Property.copy_needs_review, policy:)
    unless SAFE_POLICY_ORDER.include?(policy)
      raise ArgumentError, "Unknown safe policy #{policy.inspect} (expected one of #{SAFE_POLICY_ORDER.join(', ')})"
    end

    applied = skipped = 0
    scope.find_each do |property|
      notes = property.copy_review_notes.is_a?(Hash) ? property.copy_review_notes : {}
      preview = notes["cleaned_preview"].is_a?(Hash) ? notes["cleaned_preview"] : {}

      unless policy_match?(policy, notes, property)
        skipped += 1
        next
      end

      apply_preview_to_property!(property, preview, notes, policy: policy)
      applied += 1
    end
    { policy: policy, applied: applied, skipped: skipped }
  end

  def self.policy_match?(policy, notes, property)
    case policy
    when "safe_size_rematch" then safe_size_rematch_from_notes?(notes, property)
    when "safe_half_bath_rematch" then safe_half_bath_rematch_from_notes?(notes, property)
    when "safe_size_and_half_bath_rematch" then safe_size_and_half_bath_rematch_from_notes?(notes, property)
    when "safe_size_and_nil_fill_specs_rematch" then safe_size_and_nil_fill_specs_from_notes?(notes, property)
    when "safe_type_rematch" then safe_type_rematch_from_notes?(notes, property)
    when "safe_sparse_copy_rematch" then safe_sparse_copy_rematch_from_notes?(notes, property)
    else false
    end
  end

  # Classic/material size rematch + only nil→N beds/baths with literal title/desc
  # evidence. Caps fills at 7 to skip multi-unit aggregates (8+ beds).
  def self.safe_size_and_nil_fill_specs_from_notes?(notes, property)
    return false if blocked_review_notes?(notes)

    mismatches = Array(notes["mismatches"])
    size_mms = mismatches.select { |m| SIZE_FIELDS.include?(m["field"].to_s) }
    bed_mms = mismatches.select { |m| m["field"].to_s == "beds" }
    bath_mms = mismatches.select { |m| m["field"].to_s == "baths" }
    return false if size_mms.empty?
    return false if bed_mms.empty? && bath_mms.empty?
    return false unless mismatches.size == size_mms.size + bed_mms.size + bath_mms.size
    return false unless size_mms.any? { |m| material_size_change?(m) }

    preview = notes["cleaned_preview"].is_a?(Hash) ? notes["cleaned_preview"] : {}
    return false unless size_rematch_supported?(
      input_sqft: property.sqft,
      input_title: property.title,
      input_description: property.description_plain,
      cleaned: preview,
      mismatches: size_mms
    )

    blob = "#{property.title}\n#{property.description_plain}"
    return false unless bed_mms.all? { |m| nil_fill_beds_supported?(m, blob) }
    return false unless bath_mms.all? { |m| nil_fill_baths_supported?(m, blob) }

    true
  end

  def self.nil_model?(value)
    value.nil? || value.to_s.strip.empty? || value.to_s == "nil"
  end

  def self.nil_fill_beds_supported?(mismatch, blob)
    return false unless nil_model?(mismatch["model"])

    after = coerce_size(mismatch["from_description"])
    return false unless after && after == after.to_i && after.between?(1, 7)

    blob.match?(/\b#{after.to_i}(?:-|\s+)(?:bed(?:room)?s?|br)\b/i)
  end

  def self.nil_fill_baths_supported?(mismatch, blob)
    return false unless nil_model?(mismatch["model"])

    after = coerce_size(mismatch["from_description"])
    return false unless after && after.between?(1, 7)

    after_s = after.to_s.sub(/\.0\z/, "")
    blob.match?(/\b#{Regexp.escape(after_s)}(?:-|\s+)(?:full\s+)?(?:baths?|bathrooms?|ba)\b/i)
  end

  # Sparse blurb only, no field mismatches: apply SEO title + cleaned description,
  # keep imported features / specs (preview often wipes amenities to []).
  def self.safe_sparse_copy_rematch_from_notes?(notes, property)
    return false if Array(notes["notes"]).any? { |n| n.to_s.match?(/hallucin/i) }
    return false unless Array(notes["notes"]).any? { |n| n.to_s.match?(/sparse source/i) }
    return false unless Array(notes["mismatches"]).empty?

    preview = notes["cleaned_preview"].is_a?(Hash) ? notes["cleaned_preview"] : {}
    return false if preview["title"].to_s.strip.blank?
    return false if preview["description"].to_s.strip.blank?
    return false unless preview_specs_match_property?(preview, property)

    true
  end

  def self.preview_specs_match_property?(preview, property)
    coerce_size(preview["beds"]) == coerce_size(property.beds) &&
      coerce_size(preview["baths"]) == coerce_size(property.baths) &&
      coerce_size(preview["sqft"]) == coerce_size(property.sqft) &&
      preview["property_type"].to_s.presence == property.property_type.to_s.presence
  end

  def self.normalize_proposed_type(value)
    text = value.to_s.strip
    return nil if text.blank?
    return nil if text.match?(/\d+\s*-?\s*bedroom|\bhome\z/i) && !Property::PROPERTY_TYPES.include?(text)
    return "Apartment" if text.match?(/\Aapartment\s+buildings?\z/i)
    return text if Property::PROPERTY_TYPES.include?(text)

    nil
  end

  def self.title_supports_type?(title, type)
    pattern = TYPE_TITLE_PATTERNS[type]
    pattern.present? && title.to_s.match?(pattern)
  end

  def self.safe_type_rematch_from_notes?(notes, property)
    return false if type_blocked_review_notes?(notes)

    mismatches = Array(notes["mismatches"])
    type_m = mismatches.find { |m| m["field"].to_s == "property_type" }
    return false unless type_m

    proposed = normalize_proposed_type(type_m["from_description"])
    return false if proposed.blank?
    return false if proposed == property.property_type.to_s
    return false unless title_supports_type?(property.title, proposed)

    true
  end

  # Title keyword evidence is enough for type — sparse blurbs should not block.
  def self.type_blocked_review_notes?(notes)
    notes["status"].to_s == "needs_review" ||
      Array(notes["notes"]).any? { |n| n.to_s.match?(/hallucin/i) }
  end

  def self.safe_size_and_half_bath_rematch_from_notes?(notes, property)
    return false if blocked_review_notes?(notes)

    mismatches = Array(notes["mismatches"])
    size_mms, bath_mms = partition_size_and_bath_mismatches(mismatches)
    return false if size_mms.empty? || bath_mms.size != 1
    return false unless mismatches.size == size_mms.size + bath_mms.size
    return false unless size_mms.any? { |m| material_size_change?(m) }
    return false unless half_bath_step_supported?(
      mismatch: bath_mms.first,
      title: property.title,
      description: property.description_plain
    )

    preview = notes["cleaned_preview"].is_a?(Hash) ? notes["cleaned_preview"] : {}
    size_rematch_supported?(
      input_sqft: property.sqft,
      input_title: property.title,
      input_description: property.description_plain,
      cleaned: preview,
      mismatches: size_mms
    )
  end

  def self.partition_size_and_bath_mismatches(mismatches)
    size_mms = mismatches.select { |m| SIZE_FIELDS.include?(m["field"].to_s) }
    bath_mms = mismatches.select { |m| m["field"].to_s == "baths" }
    [ size_mms, bath_mms ]
  end

  def self.blocked_review_notes?(notes)
    notes["status"].to_s == "needs_review" ||
      Array(notes["notes"]).any? { |n| n.to_s.match?(/sparse source|hallucin/i) }
  end

  def self.safe_half_bath_rematch_from_notes?(notes, property)
    return false if blocked_review_notes?(notes)

    mismatches = Array(notes["mismatches"])
    return false unless mismatches.size == 1 && mismatches.first["field"].to_s == "baths"

    half_bath_step_supported?(
      mismatch: mismatches.first,
      title: property.title,
      description: property.description_plain
    )
  end

  def self.half_bath_step_supported?(mismatch:, title:, description:)
    before = coerce_size(mismatch["model"])
    after = coerce_size(mismatch["from_description"])
    return false unless before && after
    return false unless (after - before).abs == 0.5

    blob = "#{title}\n#{description}"
    after_s = after.to_s.sub(/\.0\z/, "")
    return true if blob.match?(/\b#{Regexp.escape(after_s)}\s*(?:bath|bathroom|bathrooms|ba)\b/i)

    whole = after > before ? before.to_i : after.to_i
    blob.match?(/\b#{whole}\s+and\s+a\s+half\s+(?:bath|bathroom|bathrooms)\b/i)
  end

  def self.safe_size_rematch_from_notes?(notes, property)
    return false if blocked_review_notes?(notes)

    mismatches = Array(notes["mismatches"])
    return false if mismatches.empty?
    return false unless mismatches.all? { |m| SIZE_FIELDS.include?(m["field"].to_s) }
    return false unless mismatches.any? { |m| material_size_change?(m) }

    preview = notes["cleaned_preview"].is_a?(Hash) ? notes["cleaned_preview"] : {}
    size_rematch_supported?(
      input_sqft: property.sqft,
      input_title: property.title,
      input_description: property.description_plain,
      cleaned: preview,
      mismatches: mismatches
    )
  end

  def self.material_size_change?(mismatch)
    field = mismatch["field"].to_s
    before = coerce_size(mismatch["model"])
    after = coerce_size(mismatch["from_description"])
    return false if before == after
    return true if before.nil? ^ after.nil?

    delta = (before - after).abs
    if field == "acres"
      delta >= 0.05
    else
      max = [ before.abs, after.abs ].max
      delta >= 500 || (max.positive? && (delta / max) >= 0.10)
    end
  end

  def self.size_rematch_supported?(input_sqft:, input_title:, input_description:, cleaned:, mismatches:)
    cleaned_lot = coerce_size(cleaned["lot_sqft"])
    cleaned_sqft = coerce_size(cleaned["sqft"])
    imported = coerce_size(input_sqft)

    return true if imported && cleaned_lot && imported == cleaned_lot

    notes = mismatches.map { |m| m["note"].to_s }.join(" ")
    return true if notes.match?(/land|building|house size|lot size|misclassif|living space|internal/i)

    blob = "#{input_title}\n#{input_description}"
    sizes = blob.scan(/[\d,]+(?:\.\d+)?\s*(?:sq\.?\s*fts?|sqft|square\s+feet)/i)
    sizes.size >= 1 && (cleaned_lot || cleaned_sqft)
  end

  def self.coerce_size(value)
    return nil if value.nil? || value.to_s.strip.empty? || value.to_s == "nil"

    number = Float(value.to_s.gsub(/[,\s]/, ""))
    number == number.to_i ? number.to_i : number
  rescue ArgumentError, TypeError
    nil
  end

  def self.apply_preview_to_property!(property, preview, notes, policy:)
    preview = preview.deep_dup

    if policy == "safe_sparse_copy_rematch"
      property.update!(
        title: preview["title"].presence || property.title,
        description: preview["description"].presence || property.description_plain,
        copy_needs_review: false,
        copy_review_notes: {
          "status" => "ok",
          "confidence" => notes["confidence"],
          "applied_at" => Time.current.utc.iso8601,
          "policy" => policy,
          "prior_mismatches" => Array(notes["mismatches"]),
          "notes" => Array(notes["notes"]),
          "kept_features" => true
        }
      )
      return
    end

    if policy == "safe_type_rematch"
      type_m = Array(notes["mismatches"]).find { |m| m["field"].to_s == "property_type" }
      normalized = normalize_proposed_type(type_m&.dig("from_description").presence || preview["property_type"])
      preview["property_type"] = normalized if normalized.present?
    end
    attrs = {
      title: preview["title"].presence || property.title,
      address: preview["address"].presence || property.address,
      city: preview["city"].presence || property.city,
      state: preview["state"].presence || property.state,
      zip: preview["zip"].to_s,
      description: preview["description"].presence || property.description_plain,
      beds: preview.key?("beds") ? preview["beds"] : property.beds,
      baths: preview.key?("baths") ? preview["baths"] : property.baths,
      sqft: preview.key?("sqft") ? preview["sqft"] : property.sqft,
      property_type: preview["property_type"].presence || property.property_type,
      tag: preview["tag"].presence || property.tag,
      features: preview.key?("features") ? Array(preview["features"]) : Array(property.features),
      copy_needs_review: false,
      copy_review_notes: {
        "status" => "ok",
        "confidence" => notes["confidence"],
        "applied_at" => Time.current.utc.iso8601,
        "policy" => policy,
        "prior_mismatches" => Array(notes["mismatches"])
      }
    }
    attrs[:lot_sqft] = preview["lot_sqft"] if property.respond_to?(:lot_sqft=) && preview.key?("lot_sqft")
    attrs[:acres] = preview["acres"] if property.respond_to?(:acres=) && preview.key?("acres")
    property.update!(attrs)
  end

  def initialize(property, client:)
    @property = property
    @client = client
  end

  # OpenAI only: apply clean verification, otherwise flag for the dry daisy chain.
  def call
    cleaner = ListingCopyCleaner.call(@property, client: @client)

    if cleaner.applyable?
      apply_cleaned!(cleaner, policy: "ok")
      return Result.new(property: @property, cleaner_result: cleaner, applied: true, skipped: false)
    end

    flag_for_review!(cleaner)
    Result.new(property: @property, cleaner_result: cleaner, applied: false, skipped: true)
  rescue OpenaiClient::Error, ListingCopyCleaner::Error => e
    flag_for_review!(nil, error: e.message)
    Result.new(property: @property.reload, cleaner_result: nil, applied: false, skipped: true, error: e.message)
  end

  private

  def flag_for_review!(cleaner, error: nil)
    notes = {
      "status" => cleaner&.status || "error",
      "confidence" => cleaner&.verification&.dig("confidence"),
      "mismatches" => Array(cleaner&.verification&.dig("mismatches")),
      "notes" => Array(cleaner&.verification&.dig("notes")),
      "scenario" => error.presence || cleaner&.mismatch_scenario || "Copy cleaner error",
      "cleaned_preview" => preview_from(cleaner),
      "checked_at" => Time.current.utc.iso8601
    }

    @property.update!(copy_needs_review: true, copy_review_notes: notes)
  end

  def apply_cleaned!(cleaner, policy:)
    cleaned = cleaner.cleaned
    attrs = {
      title: cleaned["title"],
      address: cleaned["address"].presence || @property.address,
      city: cleaned["city"].presence || @property.city,
      state: cleaned["state"].presence || @property.state,
      zip: cleaned["zip"].to_s,
      description: cleaned["description"].presence || @property.description_plain,
      beds: cleaned["beds"],
      baths: cleaned["baths"],
      sqft: cleaned["sqft"],
      property_type: cleaned["property_type"],
      tag: cleaned["tag"],
      features: Array(cleaned["features"]),
      copy_needs_review: false,
      copy_review_notes: {
        "status" => "ok",
        "confidence" => cleaner.verification["confidence"],
        "applied_at" => Time.current.utc.iso8601,
        "policy" => policy,
        "prior_mismatches" => Array(cleaner.verification["mismatches"])
      }
    }

    attrs[:lot_sqft] = cleaned["lot_sqft"] if @property.respond_to?(:lot_sqft=)
    attrs[:acres] = cleaned["acres"] if @property.respond_to?(:acres=)

    @property.update!(attrs)
  end

  def preview_from(cleaner)
    return {} unless cleaner

    cleaned = cleaner.cleaned || {}
    APPLY_KEYS.index_with { |key| cleaned[key] }
  end
end
