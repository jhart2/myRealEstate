# Formats listing money for display with a fixed FX table.
#
# Stored `price_cents` are treated as BASE_CURRENCY (default USD) — the same
# units already shown with bare `$` in seeds/admin placeholders.
#
# Approximate rates vs TTD (update periodically; not live FX):
#   1 USD ≈ 6.75 TTD
#   1 CAD ≈ 5.00 TTD
class MoneyDisplay
  CURRENCIES = %w[TTD USD CAD].freeze

  # Stored listing amounts are in this currency's minor units (cents).
  BASE_CURRENCY = ENV.fetch("CURRENCY_BASE", "USD").upcase.freeze

  # First-visit / cookie-missing default for the Trinidad site.
  DEFAULT_CURRENCY = ENV.fetch("CURRENCY_DEFAULT", "TTD").upcase.freeze

  # Units of TTD per 1 unit of the given currency.
  RATES_TO_TTD = {
    "TTD" => BigDecimal("1"),
    "USD" => BigDecimal("6.75"),
    "CAD" => BigDecimal("5.0")
  }.freeze

  SYMBOLS = {
    "TTD" => "TT$",
    "USD" => "$",
    "CAD" => "C$"
  }.freeze

  class << self
    def normalize(code)
      code = code.to_s.upcase
      CURRENCIES.include?(code) ? code : DEFAULT_CURRENCY
    end

    # Convert minor units from BASE_CURRENCY into `to` currency.
    def convert_cents(cents, to:, from: BASE_CURRENCY)
      from = normalize(from)
      to = normalize(to)
      amount = BigDecimal(cents.to_i.to_s)
      return amount.round.to_i if from == to

      from_rate = RATES_TO_TTD.fetch(from)
      to_rate = RATES_TO_TTD.fetch(to)
      (amount * from_rate / to_rate).round.to_i
    end

    def format(cents, currency: DEFAULT_CURRENCY, rent: false)
      converted = convert_cents(cents, to: currency)
      dollars = converted / 100.0
      body = "#{symbol(currency)}#{ActiveSupport::NumberHelper.number_to_delimited(dollars.to_i)}"
      rent ? "#{body} / mo" : body
    end

    # Compact labels for map price pills ($4.8M, TT$32.1M, …).
    def compact(cents, currency: DEFAULT_CURRENCY, rent: false)
      converted = convert_cents(cents, to: currency)
      dollars = converted.to_f / 100.0
      sym = symbol(currency)

      if rent
        dollars >= 1_000 ? "#{sym}#{(dollars / 1_000).round(1)}K" : "#{sym}#{dollars.to_i}"
      elsif dollars >= 1_000_000
        "#{sym}#{(dollars / 1_000_000).round(1)}M"
      elsif dollars >= 1_000
        "#{sym}#{(dollars / 1_000).round(0)}K"
      else
        "#{sym}#{dollars.to_i}"
      end
    end

    def per_sqft(cents, sqft, currency: DEFAULT_CURRENCY)
      return nil if sqft.to_i <= 0 || cents.to_i <= 0

      converted = convert_cents(cents, to: currency)
      per = (converted / 100.0 / sqft.to_f).round
      "#{symbol(currency)}#{ActiveSupport::NumberHelper.number_to_delimited(per)} price/sqft"
    end

    def symbol(currency)
      SYMBOLS.fetch(normalize(currency))
    end

    def rates_payload
      {
        base: BASE_CURRENCY,
        default: DEFAULT_CURRENCY,
        ratesToTtd: RATES_TO_TTD.transform_values(&:to_s)
      }
    end
  end
end
