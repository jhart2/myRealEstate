module ApplicationHelper
  CATEGORIES = [
    { label: "Houses", type: "House", image: "https://images.unsplash.com/photo-1566908829550-e6551b00979b?w=600&h=400&fit=crop&auto=format" },
    { label: "Apartments", type: "Apartment", image: "https://images.unsplash.com/photo-1760887497519-3b1c5a525836?w=600&h=400&fit=crop&auto=format" },
    { label: "Townhouses", type: "Townhouse", image: "https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=600&h=400&fit=crop&auto=format" },
    { label: "Commercial", type: "Commercial", image: "https://images.unsplash.com/photo-1770622006495-86de934162b5?w=600&h=400&fit=crop&auto=format" },
    { label: "Land", type: "Land", image: "https://images.unsplash.com/photo-1500382017468-9049fed747ef?w=600&h=400&fit=crop&auto=format" },
    { label: "Villas", type: "Villa", image: "https://images.unsplash.com/photo-1762811054947-605b20298615?w=600&h=400&fit=crop&auto=format" }
  ].freeze

  def page_title(title = nil)
    content_for?(:title) ? content_for(:title) : (title || "TT Realty")
  end

  def nav_link_to(name, path, **options)
    active = current_page?(path)
    classes = "text-sm font-medium transition-colors #{active ? 'text-ink' : 'text-ink-2 hover:text-ink'}"
    link_to name, path, class: classes, **options
  end

  def flash_class(type)
    case type.to_sym
    when :notice then "bg-stone-light text-ink border-trinidad"
    when :alert then "bg-red-50 text-red-800 border-red-200"
    else "bg-panel-warm text-ink border-border"
    end
  end

  def property_type_count(type, counts)
    counts.fetch(type, 0)
  end

  def page_document_title
    brand = "TT Realty"
    return brand unless content_for?(:title)

    heading = strip_tags(content_for(:title).to_s).gsub("&amp;", "&").squish
    "#{heading} · #{brand}"
  end

  # Zillow-style SEO heading: "{Location} Real Estate & Homes For Sale"
  def property_search_heading(location = nil)
    place = location.to_s.strip.presence
    if place
      "#{titleize_place(place)} Real Estate & Homes For Sale"
    else
      "Trinidad Real Estate & Homes For Sale"
    end
  end

  def property_search_meta_description(location: nil, count: 0)
    place = location.to_s.strip.presence || "Trinidad"
    homes = count == 1 ? "1 home" : "#{number_with_delimiter(count)} homes"
    "Browse #{homes} for sale in #{titleize_place(place)}. Explore listings with TT Realty."
  end

  def search_intent_chip_label(intent)
    case intent.to_s
    when "sale" then "For sale"
    when "rent" then "For rent"
    when "new" then "New listings"
    else "For sale"
    end
  end

  def search_price_chip_label(budget, price_min = nil, price_max = nil)
    if price_min.present? || price_max.present?
      return format_price_range_chip(price_min, price_max)
    end

    label = budget.to_s.strip
    return "Price" if label.blank? || label == "Any Price"

    label.gsub("Under ", "≤ ").gsub(" – ", "–")
  end

  def format_price_range_chip(price_min, price_max)
    min_n = price_min.to_i
    max_n = price_max.to_s.strip
    has_max = max_n.present? && max_n.to_i > 0

    if min_n <= 0 && !has_max
      "Price"
    elsif min_n <= 0 && has_max
      "≤ #{short_money(max_n.to_i)}"
    elsif has_max
      "#{short_money(min_n)}–#{short_money(max_n.to_i)}"
    else
      "#{short_money(min_n)}+"
    end
  end

  def short_money(dollars)
    n = dollars.to_i
    if n >= 1_000_000
      val = n / 1_000_000.0
      "$#{(val % 1).zero? ? val.to_i : format('%.1f', val)}M"
    elsif n >= 1_000
      "$#{(n / 1_000.0).round}K"
    else
      "$#{n}"
    end
  end

  def search_price_filter_active?(budget, price_min = nil, price_max = nil)
    return true if price_min.present? && price_min.to_i > 0
    return true if price_max.present? && price_max.to_i > 0
    budget.present? && budget != "Any Price"
  end

  # Beds/baths/sqft (and similar counts): nil, blank, and 0 mean "unknown" — hide in listing UX.
  def property_spec_present?(value)
    value.present? && value.to_i.positive?
  end

  def search_beds_baths_chip_label(beds, baths = nil)
    parts = []
    parts << "#{beds}+ bd" if beds.present?
    parts << "#{baths}+ ba" if baths.present?
    parts.any? ? parts.join(", ") : "Beds & baths"
  end

  def search_property_type_chip_label(property_types)
    types = Array(property_types).map(&:presence).compact
    return "Property type" if types.empty?
    return types.first if types.size == 1

    "#{types.size} types"
  end

  def search_more_filters_active?(sort:, sqft_min: nil, sqft_max: nil, acres_min: nil, days_max: nil, featured_only: false)
    return true if sort.present? && sort != "featured"
    return true if sqft_min.present? || sqft_max.present? || acres_min.present? || days_max.present?
    featured_only
  end

  def search_filter_chevron
    %(<svg class="search-filter-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>).html_safe
  end

  def titleize_place(place)
    place.to_s.strip.split(/\s+/).map { |part|
      part.split("-").map { |chunk|
        chunk.match?(/\A(nc|tt|usa|uk)\z/i) ? chunk.upcase : chunk.capitalize
      }.join("-")
    }.join(" ")
  end

  def can_edit_listing?(property)
    return false unless authenticated? && property.present?
    return true if admin?

    current_agent.present? && property.agent_id == current_agent.id
  end

  def listing_edit_path_for(property)
    admin? ? edit_admin_property_path(property) : edit_portal_property_path(property)
  end

  # Wraps a money label so Stimulus currency controller can reformat in place.
  def money_amount(cents, format: :full, rent: false, sqft: nil, currency: current_currency, **html_options)
    format_name = format.to_sym
    text =
      case format_name
      when :compact
        MoneyDisplay.compact(cents, currency: currency, rent: rent)
      when :per_sqft
        MoneyDisplay.per_sqft(cents, sqft, currency: currency)
      else
        MoneyDisplay.format(cents, currency: currency, rent: rent)
      end
    return if text.blank?

    data = (html_options.delete(:data) || {}).stringify_keys
    data = data.merge(
      "money" => true,
      "money-cents" => cents.to_i,
      "money-format" => format_name.to_s,
      "money-rent" => rent ? "true" : "false"
    )
    data["money-sqft"] = sqft.to_i if format_name == :per_sqft && sqft.present?

    tag.span(text, **html_options, data: data)
  end

  def property_money(property, format: :full, **html_options)
    money_amount(
      property.price_cents,
      format: format,
      rent: property.tag == "rent",
      sqft: (format.to_sym == :per_sqft ? property.sqft : nil),
      **html_options
    )
  end
end
