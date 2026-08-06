# Parses lot / acreage hints from listing title + description text.
class LotSizeExtractor
  SQFT_PER_ACRE = BigDecimal("43560")

  Result = Data.define(:acres, :lot_sqft)

  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    from_acres || from_half_acre || from_land_sqft
  end

  private

  attr_reader :text

  def from_acres
    match = text.match(/(\d+(?:\.\d+)?)\s*-?\s*acres?\b/i)
    return nil unless match

    acres = BigDecimal(match[1])
    return nil if acres <= 0 || acres > 10_000

    Result.new(acres: acres.round(4), lot_sqft: (acres * SQFT_PER_ACRE).round)
  end

  def from_half_acre
    return nil unless text.match?(/\bhalf[\s-]?acre\b/i)

    acres = BigDecimal("0.5")
    Result.new(acres: acres, lot_sqft: (acres * SQFT_PER_ACRE).round)
  end

  def from_land_sqft
    patterns = [
      /(?:freehold\s+|leasehold\s+)?land[:\s]+(?:–|-)?\s*([\d,]+)\s*(?:sq\.?\s*ft\.?|sqft)/i,
      /on\s+([\d,]+)\s*(?:sq\.?\s*ft\.?|sqft)\s+(?:of\s+)?(?:freehold\s+|leasehold\s+)?land/i,
      /([\d,]+)\s*(?:sq\.?\s*ft\.?|sqft)\s+of\s+(?:freehold\s+|manicured\s+)?(?:land|grounds)/i,
      /lot\s+sizes?\s*[~≈]?\s*([\d,]+)\s*(?:sq\.?\s*ft\.?|sqft)/i
    ]

    patterns.each do |pattern|
      match = text.match(pattern)
      next unless match

      lot = match[1].to_s.gsub(",", "").to_i
      next if lot < 500 || lot > 50_000_000

      acres = (BigDecimal(lot) / SQFT_PER_ACRE).round(4)
      return Result.new(acres: acres, lot_sqft: lot)
    end

    nil
  end
end
