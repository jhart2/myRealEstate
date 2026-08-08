class AgentsController < ApplicationController
  allow_unauthenticated_access only: %i[index show]

  def index
    @agents = Agent.active.featured.with_attached_image
  end

  def show
    @agent = Agent.active.with_attached_image.find(params[:id].to_s.split("-").first)
    @properties = @agent.properties.active.includes(image_attachment: :blob).with_attached_gallery_images.order(featured: :desc, created_at: :desc)
    @inquiry = Inquiry.new(agent: @agent, name: current_user&.name, email: current_user&.email_address)
  end
end
