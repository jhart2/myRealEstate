class HomeController < ApplicationController
  allow_unauthenticated_access

  def index
    @featured_properties = Property.featured.includes(:agent).limit(6)
    @properties = Property.active.includes(:agent, image_attachment: :blob).order(featured: :desc, created_at: :desc).limit(6)
    @agents = Agent.show_on_homepage.with_attached_image.limit(4)
    @category_counts = Property.active.group(:property_type).count
  end
end
