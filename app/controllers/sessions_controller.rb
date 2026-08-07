class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
    redirect_with_login_failure("Try again later.")
  }

  def new
    @auth_modal_auto_open = params[:auth].presence || "login"
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_with_login_failure("Try another email address or password.")
    end
  end

  def destroy
    terminate_session
    redirect_to root_path, status: :see_other
  end

  private
    def redirect_with_login_failure(message)
      path_opts = { email_address: params[:email_address] }
      if params[:modal].present?
        path_opts[:auth] = "login"
        redirect_to modal_auth_redirect_path(**path_opts), alert: message
      else
        redirect_to new_session_path(path_opts.compact), alert: message
      end
    end
end
