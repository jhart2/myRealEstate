module Admin
  class DuplicatesController < BaseController
    before_action :set_pair, only: %i[show update]

    def index
      @pairs = queued_pairs
      @properties_by_id = Property
        .where(id: @pairs.flat_map { |p| [ p.left_id, p.right_id ] }.uniq)
        .includes(:agent, image_attachment: :blob)
        .index_by(&:id)
      @flagged_count = Property.possible_duplicates.count
      @pair_count = @pairs.size
    end

    def show
    end

    def update
      action = params[:reconcile].presence || params[:commit].to_s

      case action
      when "keep_both"
        clear_flags!(@left, @right)
        redirect_after_resolve!("Cleared duplicate flags on both listings.")
      when "drop_both"
        drop_both!(@left, @right)
        redirect_after_resolve!("Disabled both #{@left.slug} and #{@right.slug}.")
      when "keep_left"
        keep_one!(keep: @left, drop: @right)
        redirect_after_resolve!("Kept #{@left.slug}; disabled #{@right.slug}.")
      when "keep_right"
        keep_one!(keep: @right, drop: @left)
        redirect_after_resolve!("Kept #{@right.slug}; disabled #{@left.slug}.")
      when "clear_left"
        @left.update!(possible_duplicate: false)
        redirect_after_resolve!("Cleared flag on #{@left.slug}.")
      when "clear_right"
        @right.update!(possible_duplicate: false)
        redirect_after_resolve!("Cleared flag on #{@right.slug}.")
      else
        redirect_to admin_duplicate_path(@left, peer: @right.to_param), alert: "Unknown action."
      end
    end

    private

    def set_pair
      @left = Property.find_by(slug: params[:id]) || Property.find(params[:id])
      peer_param = params[:peer].presence

      @right =
        if peer_param
          Property.find_by(slug: peer_param) || Property.find_by(id: peer_param)
        else
          peer_from_queue(@left)
        end

      raise ActiveRecord::RecordNotFound if @right.blank?

      @signals = PropertyDuplicateDetector.signals_between(@left, @right)
      @score = @signals.size
    end

    def peer_from_queue(property)
      pair = queued_pairs.find { |p| p.left_id == property.id || p.right_id == property.id }
      return nil unless pair

      peer_id = pair.left_id == property.id ? pair.right_id : pair.left_id
      Property.find_by(id: peer_id)
    end

    def clear_flags!(*properties)
      Property.where(id: properties.map(&:id)).update_all(possible_duplicate: false)
    end

    def keep_one!(keep:, drop:)
      drop.update!(status: "disabled", possible_duplicate: false)
      keep.update!(possible_duplicate: false)
    end

    def drop_both!(*properties)
      Property.where(id: properties.map(&:id)).update_all(status: "disabled", possible_duplicate: false)
    end

    def redirect_after_resolve!(notice)
      pairs = queued_pairs
      sweep_orphan_flags!(queue: pairs)

      next_pair = pairs.find { |pair| !same_pair?(pair, @left.id, @right.id) }
      if next_pair && (left = Property.find_by(id: next_pair.left_id)) && next_pair.right_slug.present?
        redirect_to admin_duplicate_path(left, peer: next_pair.right_slug),
                    notice: "#{notice} Loading next pair."
      else
        redirect_to admin_duplicates_path, notice: "#{notice} Queue is empty."
      end
    end

    def queued_pairs
      @queued_pairs ||= begin
        flagged_ids = Property.possible_duplicates.pluck(:id).to_set
        return [] if flagged_ids.empty?

        # Both sides must still be flagged. Otherwise resolving A↔B still resurfaces
        # A↔C because C remains flagged.
        PropertyDuplicateDetector
          .call(dry_run: true, limit_pairs: 5_000)
          .pairs
          .select { |pair| flagged_ids.include?(pair.left_id) && flagged_ids.include?(pair.right_id) }
      end
    end

    def sweep_orphan_flags!(queue: queued_pairs)
      flagged_ids = Property.possible_duplicates.pluck(:id)
      return if flagged_ids.empty?

      still_needed = queue.flat_map { |p| [ p.left_id, p.right_id ] }.uniq
      orphans = flagged_ids - still_needed
      Property.where(id: orphans).update_all(possible_duplicate: false) if orphans.any?
    end

    def same_pair?(pair, left_id, right_id)
      (pair.left_id == left_id && pair.right_id == right_id) ||
        (pair.left_id == right_id && pair.right_id == left_id)
    end
  end
end
