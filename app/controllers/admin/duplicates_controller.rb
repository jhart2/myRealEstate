module Admin
  class DuplicatesController < BaseController
    before_action :set_pair, only: %i[show update]

    def index
      detection = PropertyDuplicateDetector.call(dry_run: true, limit_pairs: 2_000)
      @pairs = queue_pairs(detection.pairs)
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
      case params[:commit].to_s
      when "keep_both"
        clear_flags!(@left, @right)
        redirect_after_resolve!("Cleared duplicate flags on both listings.")
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
      detection = PropertyDuplicateDetector.call(dry_run: true, limit_pairs: 5_000)

      peer_param = params[:peer].presence
      @right =
        if peer_param
          Property.find_by(slug: peer_param) || Property.find_by(id: peer_param)
        else
          peer_from_detection(@left, detection)
        end

      raise ActiveRecord::RecordNotFound if @right.blank?

      @signals = signals_from_detection(@left, @right, detection)
      @score = @signals.size
    end

    def peer_from_detection(property, detection)
      pair = queue_pairs(detection.pairs).find { |p| p.left_id == property.id || p.right_id == property.id }
      return nil unless pair

      peer_id = pair.left_id == property.id ? pair.right_id : pair.left_id
      Property.find_by(id: peer_id)
    end

    def signals_from_detection(left, right, detection)
      pair = detection.pairs.find { |p|
        (p.left_id == left.id && p.right_id == right.id) ||
          (p.left_id == right.id && p.right_id == left.id)
      }
      pair&.signals || []
    end

    def clear_flags!(*properties)
      Property.where(id: properties.map(&:id)).update_all(possible_duplicate: false)
    end

    def keep_one!(keep:, drop:)
      drop.update!(status: "disabled", possible_duplicate: false)
      keep.update!(possible_duplicate: false)
    end

    def redirect_after_resolve!(notice)
      path = next_reconcile_path(after_left: @left, after_right: @right)
      if path
        redirect_to path, notice: "#{notice} Loading next pair."
      else
        redirect_to admin_duplicates_path, notice: "#{notice} Queue is empty."
      end
    end

    def next_reconcile_path(after_left:, after_right:)
      detection = PropertyDuplicateDetector.call(dry_run: true, limit_pairs: 5_000)
      next_pair = queue_pairs(detection.pairs).find { |pair|
        !same_pair?(pair, after_left.id, after_right.id)
      }
      return nil unless next_pair

      left = Property.find_by(id: next_pair.left_id)
      right_slug = next_pair.right_slug
      return nil if left.blank? || right_slug.blank?

      admin_duplicate_path(left, peer: right_slug)
    end

    def queue_pairs(pairs)
      flagged_ids = Property.possible_duplicates.pluck(:id).to_set
      return [] if flagged_ids.empty?

      pairs.select { |pair| flagged_ids.include?(pair.left_id) || flagged_ids.include?(pair.right_id) }
    end

    def same_pair?(pair, left_id, right_id)
      (pair.left_id == left_id && pair.right_id == right_id) ||
        (pair.left_id == right_id && pair.right_id == left_id)
    end
  end
end
