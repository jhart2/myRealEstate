class InquiriesController < ApplicationController
  allow_unauthenticated_access only: :create

  def create
    @inquiry = Inquiry.new(inquiry_params)
    @inquiry.user = current_user if authenticated?
    @inquiry.status = "new"

    if @inquiry.save
      redirect_back fallback_location: root_path, notice: "Thanks — an advisor will reach out shortly."
    else
      redirect_back fallback_location: root_path, alert: @inquiry.errors.full_messages.to_sentence
    end
  end

  private

  def inquiry_params
    params.require(:inquiry).permit(:name, :email, :phone, :message, :property_id, :agent_id)
  end
end
