# Syncs Tag + PropertyTag rows from hashtags found in listing copy.
class PropertyHashtagTagger
  def self.call(property, replace: true)
    new(property, replace: replace).call
  end

  def self.backfill!(scope: Property.all, replace: true)
    created_tags = 0
    created_joins = 0
    touched = 0

    scope = scope.with_rich_text_description if scope.respond_to?(:with_rich_text_description)

    scope.find_each(batch_size: 200) do |property|
      result = call(property, replace: replace)
      next unless result[:changed]

      touched += 1
      created_tags += result[:tags_created]
      created_joins += result[:joins_created]
    end

    Tag.find_each(&:refresh_listings_count!)

    {
      listings_touched: touched,
      tags_created: created_tags,
      joins_created: created_joins,
      tag_total: Tag.count,
      join_total: PropertyTag.count
    }
  end

  def initialize(property, replace: true)
    @property = property
    @replace = replace
  end

  def call
    desired = HashtagTagExtractor.extract(@property)
    tags_created = 0
    joins_created = 0
    changed = false

    tag_records = desired.map do |attrs|
      tag = Tag.find_or_initialize_by(slug: attrs[:slug])
      if tag.new_record?
        tag.name = attrs[:name]
        tag.save!
        tags_created += 1
        changed = true
      elsif tag.name.blank? || tag.name.length < attrs[:name].length
        tag.update!(name: attrs[:name])
        changed = true
      end
      tag
    end

    desired_ids = tag_records.map(&:id)

    if @replace
      stale = @property.property_tags.where.not(tag_id: desired_ids)
      if stale.exists?
        stale.delete_all
        changed = true
      end
    end

    tag_records.each do |tag|
      next if @property.property_tags.exists?(tag_id: tag.id)

      @property.property_tags.create!(tag: tag)
      joins_created += 1
      changed = true
    end

    {
      tags: desired.size,
      tags_created: tags_created,
      joins_created: joins_created,
      changed: changed
    }
  end
end
