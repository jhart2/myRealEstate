module AdminHelper
  def admin_user_initials(user = current_user)
    parts = user&.name.to_s.split(/\s+/).reject(&:blank?)
    return "?" if parts.empty?

    parts.first(2).map { |part| part[0] }.join.upcase
  end

  def admin_section_active?(section)
    path = request.path
    case section.to_sym
    when :dashboard then path == admin_root_path || path == "/admin"
    when :properties then path.start_with?("/admin/properties")
    when :agents then path.start_with?("/admin/agents")
    when :inquiries then path.start_with?("/admin/inquiries")
    when :copy_reviews then path.start_with?("/admin/copy_reviews")
    when :duplicates then path.start_with?("/admin/duplicates")
    else false
    end
  end

  def admin_status_led_class(status)
    case status.to_s
    when "active" then "bg-emerald-500 shadow-[0_0_0_3px_rgba(16,185,129,0.22)]"
    when "pending" then "bg-amber-400 shadow-[0_0_0_3px_rgba(251,191,36,0.25)]"
    when "sold" then "bg-ink-3 shadow-[0_0_0_3px_rgba(138,127,120,0.2)]"
    when "rented" then "bg-sky-500 shadow-[0_0_0_3px_rgba(14,165,233,0.2)]"
    when "disabled" then "bg-red-400 shadow-[0_0_0_3px_rgba(248,113,113,0.25)]"
    else "bg-ink-3"
    end
  end

  def admin_status_badge_class(status)
    case status.to_s
    when "active" then "bg-emerald-50 text-emerald-800"
    when "pending" then "bg-amber-50 text-amber-900"
    when "sold" then "bg-[#efece7] text-ink-2"
    when "rented" then "bg-sky-50 text-sky-900"
    when "disabled" then "bg-red-50 text-red-800"
    else "bg-panel-warm text-ink-2"
    end
  end

  def admin_status_dot_class(status)
    case status.to_s
    when "active" then "bg-emerald-500"
    when "pending" then "bg-amber-400"
    when "sold" then "bg-ink-3"
    when "rented" then "bg-sky-500"
    when "disabled" then "bg-red-400"
    else "bg-ink-3"
    end
  end

  def admin_status_options
    Property::STATUSES.map { |status| [ Property::STATUS_LABELS.fetch(status, status.titleize), status ] }
  end

  def admin_open_inquiry_count
    return @admin_open_inquiry_count if defined?(@admin_open_inquiry_count)

    @admin_open_inquiry_count = Inquiry.open.count
  end

  def admin_copy_review_count
    return @admin_copy_review_count if defined?(@admin_copy_review_count)

    @admin_copy_review_count = Property.copy_needs_review.count
  end

  def admin_duplicate_count
    return @admin_duplicate_count if defined?(@admin_duplicate_count)

    @admin_duplicate_count = Property.possible_duplicates.count
  end

  def admin_filter_query(overrides = {})
    {
      q: params[:q].presence,
      status: params[:status].presence,
      tag: params[:tag].presence,
      sort: params[:sort].presence,
      page: params[:page].presence
    }.merge(overrides).compact
  end

  def admin_page_window(current:, total:, radius: 2)
    return (1..total).to_a if total <= 7

    start_page = [ current - radius, 1 ].max
    end_page = [ current + radius, total ].min
    start_page = [ end_page - (radius * 2), 1 ].max
    end_page = [ start_page + (radius * 2), total ].min
    (start_page..end_page).to_a
  end
end
