module Portal
  class DashboardController < BaseController
    def index
      @properties = agent.properties.order(updated_at: :desc).limit(5)
      @open_inquiries = agent.inquiries.open.recent.includes(:property).limit(8)
      @stats = {
        listings: agent.properties.count,
        active: agent.properties.active.count,
        inquiries: agent.inquiries.open.count,
        experience: agent.years_experience
      }
    end
  end
end
