module Admin
  class InquiriesController < BaseController
    before_action :set_inquiry, only: %i[show update]

    def index
      @inquiries = Inquiry.recent.includes(:property, :agent, :user)
    end

    def show
    end

    def update
      if @inquiry.update(inquiry_params)
        redirect_to admin_inquiry_path(@inquiry), notice: "Inquiry updated."
      else
        render :show, status: :unprocessable_entity
      end
    end

    private

    def set_inquiry
      @inquiry = Inquiry.find(params[:id])
    end

    def inquiry_params
      params.require(:inquiry).permit(:status)
    end
  end
end
