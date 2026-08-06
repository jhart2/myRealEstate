class ApplicationController < ActionController::Base
  include Authentication

  allow_browser versions: :modern

  helper_method :admin?, :agent_user?, :current_agent

  private

  def require_admin
    unless admin?
      redirect_to root_path, alert: "You need admin access for that."
    end
  end

  def require_agent
    unless agent_user? && current_agent
      redirect_to root_path, alert: "You need an agent account for that."
    end
  end

  def admin?
    current_user&.admin?
  end

  def agent_user?
    current_user&.agent? || current_user&.admin?
  end

  def current_agent
    return @current_agent if defined?(@current_agent)
    @current_agent = current_user&.agent_profile
  end
end
