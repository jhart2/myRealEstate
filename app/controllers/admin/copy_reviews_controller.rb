module Admin
  class CopyReviewsController < BaseController
    before_action :set_property, only: %i[show update]

    def index
      @properties = Property.copy_needs_review.includes(:agent).order(updated_at: :desc)
    end

    def show
    end

    def update
      case params[:commit].to_s
      when "clear"
        @property.update!(copy_needs_review: false)
        redirect_to admin_copy_reviews_path, notice: "Cleared copy review flag."
      when "keep_flagged"
        redirect_to admin_copy_review_path(@property), notice: "Still flagged for review."
      else
        redirect_to admin_copy_review_path(@property), alert: "Unknown action."
      end
    end

    private

    def set_property
      scope = Property.copy_needs_review
      @property = scope.find_by(slug: params[:id]) || scope.find(params[:id])
    end
  end
end
