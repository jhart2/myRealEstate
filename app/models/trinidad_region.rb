# frozen_string_literal: true

# Classifies Trinidad & Tobago listings into homepage carousel regions.
class TrinidadRegion
  Entry = Data.define(:key, :label, :slug)

  ALL = [
    Entry.new(key: "north_west", label: "North West", slug: "north-west"),
    Entry.new(key: "north_east", label: "North East", slug: "north-east"),
    Entry.new(key: "central", label: "Central", slug: "central"),
    Entry.new(key: "south_west", label: "South West", slug: "south-west"),
    Entry.new(key: "south_east", label: "South East", slug: "south-east")
  ].freeze

  BY_KEY = ALL.index_by(&:key).freeze
  BY_SLUG = ALL.index_by(&:slug).freeze

  # Longer phrases first — matching against messy `city` strings from listing feeds.
  KEYWORDS = {
    "north_west" => [
      "port of spain", "diego martin", "st. ann's", "st anns", "st. ann", "st ann",
      "petit valley", "goodwood park", "diamond vale", "alyce glen", "haleland park",
      "maraval", "westmoorings", "cascade", "woodbrook", "glencoe", "chaguaramas",
      "carenage", "st. james", "st james", "belmont", "cocorite", "moka", "paramin",
      "bayshore", "hillsboro", "fairways", "gasparee"
    ],
    "north_east" => [
      "sangre grande", "santa rosa", "d'abadie", "dabadie", "tobago plantations",
      "signal hill", "mary's hill", "arima", "toco", "blanchisseuse", "valencia",
      "cumuto", "coryal", "tobago", "scarborough", "bacolet", "lambeau"
    ],
    "central" => [
      "st. augustine", "st augustine", "st. joseph", "st joseph", "san juan",
      "longdenville", "carapichaima", "kelly village", "chin chin", "las lomas",
      "jerningham", "charlieville", "chaguanas", "couva", "freeport", "cunupia",
      "valsayn", "trincity", "tunapuna", "curepe", "barataria", "endeavour",
      "california", "preysal", "tacarigua", "el dorado", "arouca", "piarco",
      "caroni", "chase village", "enterprise"
    ],
    "south_west" => [
      "san fernando", "point fortin", "la romain", "gulf view", "south oropouche",
      "thick village", "ste. madeleine", "ste madeleine", "palmiste", "marabella",
      "penal", "siparia", "debe", "fyzabad", "otaheite", "cedros", "augustusville",
      "bel air", "hermitage", "phillipine", "vistabella", "gasparillo", "reform",
      "williamsville"
    ],
    "south_east" => [
      "princes town", "rio claro", "mayaro", "tableland", "guayaguayare",
      "manzanilla", "ortoire", "naparima"
    ]
  }.freeze

  def self.find(key_or_slug)
    BY_KEY[key_or_slug.to_s] || BY_SLUG[key_or_slug.to_s]
  end

  def self.classify(city:, latitude: nil, longitude: nil)
    haystack = city.to_s.downcase
    best_key = nil
    best_len = -1
    KEYWORDS.each do |key, words|
      hit = words.select { |w| haystack.include?(w) }.max_by(&:length)
      next unless hit && hit.length > best_len

      best_key = key
      best_len = hit.length
    end
    return BY_KEY[best_key] if best_key

    classify_by_coords(latitude, longitude) || BY_KEY["central"]
  end

  def self.place_label(city)
    raw = city.to_s.strip
    return "Trinidad" if raw.blank? || raw.match?(/\A(n\/a|trinidad)\z/i)

    haystack = raw.downcase
    # Longest keyword match wins so "port of spain" beats accidental substrings.
    match = KEYWORDS.values.flatten
      .select { |place| haystack.include?(place) }
      .max_by(&:length)
    return titleize_place(match) if match

    raw.split(/[,|]/).map(&:strip).reject(&:blank?).first.to_s.split(/\s+/).last(3).join(" ")
  end

  def self.titleize_place(place)
    small = %w[of the and]
    place.split.map.with_index { |w, i| (i.positive? && small.include?(w)) ? w : w.capitalize }.join(" ")
  end

  def self.classify_by_coords(lat, lng)
    return nil if lat.blank? || lng.blank?

    lat = lat.to_f
    lng = lng.to_f

    return BY_KEY["north_east"] if lat >= 11.0

    if lat >= 10.62
      return lng <= -61.42 ? BY_KEY["north_west"] : BY_KEY["north_east"]
    end

    if lat >= 10.40 && lat < 10.62 && lng.between?(-61.52, -61.28)
      return BY_KEY["central"]
    end

    lng <= -61.35 ? BY_KEY["south_west"] : BY_KEY["south_east"]
  end
  private_class_method :classify_by_coords
end
