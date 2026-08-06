class SubscriptionsController < ApplicationController
  allow_unauthenticated_access only: :create

  def create
    @subscription = Subscription.find_or_initialize_by(email: params[:email])
    @subscription.active = true

    if @subscription.save
      redirect_back fallback_location: root_path, notice: "You're subscribed to new listings."
    else
      redirect_back fallback_location: root_path, alert: @subscription.errors.full_messages.to_sentence
    end
  end
end
