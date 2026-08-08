# Extracts marketing hashtags from listing copy for Tag / PropertyTag rows.
class HashtagTagExtractor
  # Skip numeric street units like #1 / #2 — require at least one letter.
  HASHTAG_RE = /(?:^|[\s[:punct:]])#(?=\w*[A-Za-z])([A-Za-z][\w]*)/
  SCALAR_COLS = %w[title address city state location_raw price_label].freeze

  def self.extract(property)
    new(property).extract
  end

  def initialize(property)
    @property = property
  end

  def extract
    text.to_s.scan(HASHTAG_RE).flatten.filter_map do |raw|
      slug = Tag.slugify(raw)
      next if slug.blank? || slug.length < 2

      { slug: slug, name: Tag.display_name(raw) }
    end.uniq { |t| t[:slug] }
  end

  private

  def text
    parts = SCALAR_COLS.filter_map { |col|
      next unless @property.respond_to?(col)

      @property.public_send(col).to_s
    }
    parts << Array(@property.features).join(" ")
    parts << @property.description_plain
    parts.join("\n")
  end
end
