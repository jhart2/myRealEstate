class RegistrationsController < ApplicationController
  allow_unauthenticated_access

  def new
    @user = User.new
    @auth_modal_auto_open = params[:auth].presence || "signup"
  end

  def create
    @user = User.new(registration_params)
    @user.role = :buyer

    if @user.save
      start_new_session_for @user
      redirect_to registration_success_path, notice: "Welcome to TT Realty."
    elsif params[:modal].present?
      redirect_to modal_auth_redirect_path(auth: "signup"),
        alert: @user.errors.full_messages.to_sentence.presence || "Could not create account."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def registration_params
      params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
    end

    def registration_success_path
      return root_path unless params[:modal].present?

      referer = safe_same_host_referer(exclude_auth_paths: true)
      referer.present? ? strip_auth_query(referer) : root_path
    end
end
