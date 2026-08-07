namespace :fx do
  desc "Refresh OpenAI FX rates (TTD per 1 USD/CAD) and show sample conversions"
  task refresh: :environment do
    table = FxRate.refresh!
    puts "as_of:  #{table['as_of']}"
    puts "source: #{table['source']}"
    puts "notes:  #{table['notes']}"
    puts "USD:    1 USD = #{table['USD']} TTD"
    puts "CAD:    1 CAD = #{table['CAD']} TTD"
    puts
    sample = Property.where.not(bok_id: [ nil, "" ]).order(price_cents: :desc).limit(5)
    sample.each do |property|
      puts "#{property.bok_id}  stored=#{property.price_cents / 100} (TTD base)"
      puts "  TTD #{MoneyDisplay.format(property.price_cents, currency: "TTD")}"
      puts "  USD #{MoneyDisplay.format(property.price_cents, currency: "USD")}"
      puts "  CAD #{MoneyDisplay.format(property.price_cents, currency: "CAD")}"
    end
  end

  desc "Show current FX table without refreshing"
  task show: :environment do
    table = FxRate.rates
    puts table.inspect
    puts "USD display of TT$10,000,000 → #{MoneyDisplay.format(10_000_000_00, currency: "USD")}"
  end
end
