module Admin
  class DashboardController < BaseController
    def index
      @stats = {
        properties: Property.count,
        agents: Agent.count,
        inquiries: Inquiry.open.count,
        users: User.count,
        subscriptions: Subscription.active.count
      }
      @recent_inquiries = Inquiry.recent.includes(:property, :agent).limit(8)
      @recent_properties = Property.order(created_at: :desc).limit(5)
    end
  end
end
