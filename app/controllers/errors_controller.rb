class ErrorsController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_display_currency
  skip_forgery_protection

  layout "error"

  PAGES = {
    400 => {
      title: "Bad request",
      headline: "That request couldn’t be read.",
      body: "Something in the request was incomplete or invalid. Try again from the homepage."
    },
    404 => {
      title: "Page not found",
      headline: "This address isn’t on the market.",
      body: "The page may have moved, or the link is no longer active. Browse current listings or head home."
    },
    422 => {
      title: "Unprocessable",
      headline: "We couldn’t process that change.",
      body: "The form may have expired or the data couldn’t be accepted. Go back and try once more."
    },
    500 => {
      title: "Server error",
      headline: "Something went wrong on our side.",
      body: "Our team has been notified. Please try again in a moment, or browse homes while we sort it out."
    }
  }.freeze

  def show
    @status_code = extract_status_code
    @page = PAGES.fetch(@status_code) { PAGES[500] }
    render status: @status_code
  end

  private

  def extract_status_code
    code = params[:status_code].presence
    code ||= request.path_info.to_s.delete_prefix("/").split("/").first
    code = code.to_i
    (400..599).cover?(code) ? code : 500
  end
end
