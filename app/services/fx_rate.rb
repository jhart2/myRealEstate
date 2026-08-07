require "json"

# Fetches approximate FX as "units of TTD per 1 unit of currency" via OpenAI,
# with an in-process memo + Rails.cache + static fallbacks.
#
#   FxRate.to_ttd("USD")  # => BigDecimal
#   FxRate.refresh!       # force OpenAI refresh
#
class FxRate
  class Error < StandardError; end

  CACHE_KEY = "fx_rates_to_ttd/v1".freeze
  CACHE_TTL = 12.hours

  FALLBACK = {
    "TTD" => BigDecimal("1"),
    "USD" => BigDecimal("6.75"),
    "CAD" => BigDecimal("5.0")
  }.freeze

  class << self
    def to_ttd(currency)
      ensure_warmed!
      code = MoneyDisplay.normalize(currency)
      return BigDecimal("1") if code == "TTD"

      value = rates[code]
      return BigDecimal(value.to_s) if value.present?

      FALLBACK.fetch(code, FALLBACK.fetch("USD"))
    end

    def rates
      return @memo if memo_valid?

      cached = read_cache
      if cached
        @memo = cached
        return @memo
      end

      FALLBACK.dup
    end

    def refresh!(client: OpenaiClient.new)
      raise Error, "OPENAI_API_KEY is not set" unless client.configured?

      response = client.chat(
        messages: [
          {
            role: "system",
            content: <<~PROMPT
              You provide approximate foreign-exchange rates for a Trinidad & Tobago
              real-estate website. Return ONLY JSON:
              {
                "as_of": "ISO-8601 date",
                "rates_to_ttd": {
                  "USD": number,
                  "CAD": number
                },
                "notes": "one short sentence"
              }

              rates_to_ttd means: how many Trinidad & Tobago dollars (TTD) equal 1 unit
              of that currency. Example: if 1 USD ≈ 6.8 TTD, then "USD": 6.8.
              Use a realistic mid-market approximate rate for today (not historical
              archives). Set as_of to today's date. Precision to 2–4 decimals is fine.
            PROMPT
          },
          {
            role: "user",
            content: "What is today's approximate mid-market TTD cross rate for 1 USD and 1 CAD?"
          }
        ],
        temperature: 0,
        response_format: { type: "json_object" }
      )

      table = parse_payload(response[:content])
      @memo = table
      write_cache(table)
      Rails.logger.info("[FxRate] refreshed USD=#{table['USD']} CAD=#{table['CAD']} as_of=#{table['as_of']}")
      table
    end

    def clear_cache!
      @memo = nil
      @warmed = false
      Rails.cache.delete(CACHE_KEY)
    end

    # Test helper — bypass OpenAI/cache.
    def stub!(usd:, cad:, as_of: "test", notes: "stub")
      @warmed = true
      @memo = {
        "TTD" => BigDecimal("1"),
        "USD" => BigDecimal(usd.to_s),
        "CAD" => BigDecimal(cad.to_s),
        "as_of" => as_of.to_s,
        "notes" => notes.to_s,
        "source" => "stub"
      }
    end

    private

    def ensure_warmed!
      return if @warmed

      @warmed = true
      return if memo_valid?
      return if ENV["OPENAI_API_KEY"].blank?

      Thread.new do
        refresh!
      rescue StandardError => e
        Rails.logger.warn("[FxRate] background warm failed: #{e.message}")
      end
    end

    def memo_valid?
      @memo.is_a?(Hash) && @memo["USD"].present?
    end

    def read_cache
      cached = Rails.cache.read(CACHE_KEY)
      return nil unless cached.is_a?(Hash) && cached["USD"].present?

      cast_table(cached)
    end

    def write_cache(table)
      Rails.cache.write(CACHE_KEY, table, expires_in: CACHE_TTL)
    end

    def parse_payload(content)
      parsed = JSON.parse(content)
      raw = parsed["rates_to_ttd"] || parsed["ratesToTtd"] || {}
      usd = BigDecimal(raw.fetch("USD").to_s)
      cad = BigDecimal(raw.fetch("CAD").to_s)
      raise Error, "Invalid FX payload: #{parsed.inspect}" if usd <= 0 || cad <= 0

      {
        "TTD" => BigDecimal("1"),
        "USD" => usd,
        "CAD" => cad,
        "as_of" => parsed["as_of"].to_s,
        "notes" => parsed["notes"].to_s,
        "source" => "openai"
      }
    end

    def cast_table(raw)
      {
        "TTD" => BigDecimal("1"),
        "USD" => BigDecimal(raw["USD"].to_s),
        "CAD" => BigDecimal(raw["CAD"].to_s),
        "as_of" => raw["as_of"].to_s,
        "notes" => raw["notes"].to_s,
        "source" => raw["source"].to_s.presence || "cache"
      }
    end
  end
end
