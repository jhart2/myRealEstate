namespace :properties do
  desc "Backfill Tag + PropertyTag rows from marketing hashtags in listing copy"
  task backfill_hashtag_tags: :environment do
    scope = ENV["PROPERTY_ID"].present? ? Property.where(id: ENV["PROPERTY_ID"]) : Property.all
    puts "Backfilling hashtag tags for #{scope.count} properties…"
    result = PropertyHashtagTagger.backfill!(scope: scope, replace: ENV["REPLACE"] != "0")
    puts result.inspect
  end
end
