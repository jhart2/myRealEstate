module Portal
  class InquiriesController < BaseController
    before_action :set_inquiry, only: %i[show update]

    def index
      @inquiries = agent.inquiries.recent.includes(:property, :user)
    end

    def show
    end

    def update
      if @inquiry.update(inquiry_params)
        redirect_to portal_inquiry_path(@inquiry), notice: "Inquiry updated."
      else
        render :show, status: :unprocessable_entity
      end
    end

    private

    def set_inquiry
      @inquiry = agent.inquiries.find(params[:id])
    end

    def inquiry_params
      params.require(:inquiry).permit(:status)
    end
  end
end
