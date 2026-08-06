module Portal
  class BaseController < ApplicationController
    before_action :require_agent
    layout "portal"

    helper_method :agent

    private

    def agent
      current_agent
    end
  end
end
