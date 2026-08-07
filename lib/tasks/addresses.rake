namespace :addresses do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Rank property addresses with OpenAI cleanliness scores and resolve dirty ones via Google Geocoding.
    Dry-run by default. APPLY=1 to write. LIMIT=10 SCORE_BELOW=70 BOK_ID=BOK-123 OUT=tmp/out.json
  DESC
  task rank_and_backfill: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    score_below = Integer(ENV.fetch("SCORE_BELOW", "70"))
    limit = ENV["LIMIT"].presence&.then { |v| Integer(v) }

    scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    if ENV["RANDOM"].to_s == "1"
      scope = scope.reorder(Arel.sql("RANDOM()"))
    end

    puts "Address rank + Google resolve (apply=#{apply}, score_below=#{score_below}, limit=#{limit || 'all'})…"
    puts

    service = PropertyAddressBackfill.new(score_below: score_below)
    proposals = service.call(scope, limit: limit, apply: apply)

    out_path = ENV.fetch(
      "OUT",
      Rails.root.join("tmp", "address_backfill_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.json").to_s
    )

    serializable = proposals.map do |p|
      {
        "property_id" => p.property_id,
        "bok_id" => p.bok_id,
        "title" => p.title,
        "score" => p.score,
        "grade" => p.grade,
        "issues" => p.issues,
        "suggested_query" => p.suggested_query,
        "before" => p.before,
        "after" => p.after,
        "google" => p.google,
        "action" => p.action,
        "notes" => p.notes
      }
    end
    File.write(out_path, JSON.pretty_generate(serializable))

    counts = proposals.group_by(&:action).transform_values(&:size)
    proposals.each do |row|
      puts "=" * 72
      puts "#{row.bok_id}  score=#{row.score} grade=#{row.grade} action=#{row.action}"
      puts "  title: #{row.title}"
      puts "  before: #{row.before&.dig(:full_address) || row.before}"
      puts "  after:  #{row.after&.dig(:full_address)}" if row.after
      puts "  google: #{row.google&.dig(:formatted_address)} (#{row.google&.dig(:source)}, conf=#{row.google&.dig(:confidence)})" if row.google
      puts "  issues: #{Array(row.issues).join('; ')}" if row.issues.present?
      puts "  notes:  #{Array(row.notes).join('; ')}" if row.notes.present?
    end

    puts
    puts "Summary: #{counts.inspect}"
    puts "Wrote #{out_path}"
    puts apply ? "Applied updates where action=applied." : "Dry-run only. Re-run with APPLY=1 to write."
  end

  desc "Score only (no Google calls). LIMIT=10 BOK_ID= optional"
  task rank: :environment do
    unless OpenaiClient.new.configured?
      abort "OPENAI_API_KEY is not set (check .env)"
    end

    limit = Integer(ENV.fetch("LIMIT", "10"))
    scope = Property.where.not(bok_id: [ nil, "" ]).order(:id)
    scope = scope.where(bok_id: ENV["BOK_ID"]) if ENV["BOK_ID"].present?
    scope = scope.reorder(Arel.sql("RANDOM()")) if ENV["RANDOM"].to_s == "1"

    scorer = AddressCleanlinessScorer.new
    scope.limit(limit).each do |property|
      score = scorer.call(property)
      puts "#{property.bok_id}  #{score.score}/#{score.grade}  #{property.full_address}"
      puts "  issues: #{score.issues.join('; ')}" if score.issues.any?
      puts "  query:  #{score.suggested_query}"
      puts
    end
  end
end
