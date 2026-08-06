class PagesController < ApplicationController
  allow_unauthenticated_access

  def about
  end

  def contact
    @inquiry = Inquiry.new(name: current_user&.name, email: current_user&.email_address)
  end
end
