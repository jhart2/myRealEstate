class HomeController < ApplicationController
  allow_unauthenticated_access

  def index
    @region_rows = Property.homepage_region_rows(per_region: 12)
    @agents = Agent.show_on_homepage.with_attached_image.limit(4).to_a
    @category_counts = Property.active.group(:property_type).count
  end
end
