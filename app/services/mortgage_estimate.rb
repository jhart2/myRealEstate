# Simple principal + interest monthly estimate for sale listings.
# Not a full PITI quote — taxes / insurance / fees are excluded.
class MortgageEstimate
  DEFAULT_ANNUAL_RATE = BigDecimal("0.055") # ~5.5% TT residential assumption
  DEFAULT_TERM_YEARS = 30
  DEFAULT_DOWN_PAYMENT_RATE = BigDecimal("0.20")

  Result = Data.define(:monthly_cents, :loan_cents, :down_payment_cents, :annual_rate, :term_years)

  def self.for_price_cents(price_cents, **opts)
    new(**opts).call(price_cents)
  end

  # Approx list price that yields `monthly_cents` PI at current assumptions.
  def self.list_price_cents_for_monthly(monthly_cents, **opts)
    new(**opts).list_price_cents_for_monthly(monthly_cents)
  end

  def initialize(
    annual_rate: DEFAULT_ANNUAL_RATE,
    term_years: DEFAULT_TERM_YEARS,
    down_payment_rate: DEFAULT_DOWN_PAYMENT_RATE
  )
    @annual_rate = BigDecimal(annual_rate.to_s)
    @term_years = term_years.to_i
    @down_payment_rate = BigDecimal(down_payment_rate.to_s)
  end

  def call(price_cents)
    price = price_cents.to_i
    return nil if price <= 0

    down = (BigDecimal(price) * @down_payment_rate).round
    loan = price - down
    return nil if loan <= 0

    monthly_rate = @annual_rate / 12
    n = @term_years * 12
    factor = (1 + monthly_rate)**n
    payment = (loan * monthly_rate * factor / (factor - 1)).round

    Result.new(
      monthly_cents: payment.to_i,
      loan_cents: loan.to_i,
      down_payment_cents: down.to_i,
      annual_rate: @annual_rate,
      term_years: @term_years
    )
  end

  def list_price_cents_for_monthly(monthly_cents)
    payment = monthly_cents.to_i
    return 0 if payment <= 0

    monthly_rate = @annual_rate / 12
    n = @term_years * 12
    factor = (1 + monthly_rate)**n
    loan = (BigDecimal(payment) * (factor - 1) / (monthly_rate * factor)).round
    price = (loan / (1 - @down_payment_rate)).round
    [ price.to_i, 0 ].max
  end
end
