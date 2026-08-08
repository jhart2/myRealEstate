# Detects listing copy that looks scrape-/import-truncated (ellipsis or historic mid-cuts).
#
# Primary signals:
# - plain text ending with "..." / "…" (including WP-style omissions)
# - length near the old ~1200 scrape/excerpt band without a sentence terminator
#
module TruncatedDescription
  ELLIPSIS_TAIL = /(?:\.\.\.|…|\.(\s*\.){2,})\s*\z/
  SENTENCE_END = /[.!?]["')\]]?\s*\z/
  # Cluster of historically truncated BOK bodies after a [:1200]-style cut.
  NEAR_CAP = (1_100..1_350)
  STRICT_CAP = (1_185..1_215)

  module_function

  def normalize(text)
    text.to_s.gsub(/\u00a0/, " ").gsub(/\s+\z/, "").strip
  end

  def plain_for(property)
    return "" unless property

    if property.respond_to?(:description_plain)
      normalize(property.description_plain)
    else
      normalize(property.try(:description))
    end
  end

  def ellipsis?(text)
    normalize(text).match?(ELLIPSIS_TAIL)
  end

  def mid_cut?(text)
    plain = normalize(text)
    return false if plain.blank?
    return false if ellipsis?(plain)

    len = plain.length
    return true if STRICT_CAP.cover?(len) && !plain.match?(SENTENCE_END)
    return true if NEAR_CAP.cover?(len) && !plain.match?(SENTENCE_END)

    false
  end

  def suspect?(text)
    plain = normalize(text)
    return false if plain.blank?

    ellipsis?(plain) || mid_cut?(plain)
  end

  def suspect_property?(property)
    suspect?(plain_for(property))
  end

  # Prefer a scraped replacement when it clearly recovers more copy.
  def better_replacement?(old_text, new_text)
    old_plain = normalize(old_text)
    new_plain = normalize(new_text)
    return false if new_plain.blank?
    return true if old_plain.blank?
    return false if new_plain == old_plain

    old_bad = suspect?(old_plain)
    new_bad = suspect?(new_plain)
    return true if old_bad && !new_bad
    return true if old_bad && new_plain.length >= (old_plain.length * 1.15)
    return true if ellipsis?(old_plain) && new_plain.length > old_plain.length

    false
  end
end
