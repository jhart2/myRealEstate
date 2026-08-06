# Looks up archived OpenStreetMap place polygons under data/geo/boundaries.
class GeoBoundaryLookup
  ROOT = Rails.root.join("data/geo/boundaries")

  def self.find(location)
    new.find(location)
  end

  def find(location)
    key = normalize(location)
    return nil if key.blank?

    entry = index[key] || fuzzy_entry(key)
    return nil unless entry

    path = ROOT.join(entry["file"])
    return nil unless path.file?

    feature = JSON.parse(path.read)
    return nil unless feature.is_a?(Hash) && feature["geometry"].is_a?(Hash)

    feature
  rescue JSON::ParserError
    nil
  end

  private

  def index
    @index ||= begin
      path = ROOT.join("index.json")
      path.file? ? JSON.parse(path.read) : {}
    end
  end

  def normalize(location)
    location.to_s.downcase.gsub(/[.']/, "").gsub(/[^a-z0-9]+/, " ").squish
  end

  def fuzzy_entry(key)
    # Try last significant token ("Bayshore Port of Spain Westmoorings" → westmoorings / port of spain)
    tokens = key.split
    candidates = []
    tokens.size.downto(1) do |n|
      tokens.each_cons(n) { |chunk| candidates << chunk.join(" ") }
    end
    candidates.uniq.each do |candidate|
      return index[candidate] if index[candidate]
    end
    nil
  end
end
