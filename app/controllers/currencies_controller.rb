class CurrenciesController < ApplicationController
  allow_unauthenticated_access

  def update
    code = MoneyDisplay.normalize(params[:currency])
    cookies.permanent[:currency] = {
      value: code,
      httponly: false,
      same_site: :lax
    }
    Current.currency = code

    respond_to do |format|
      format.html { redirect_back fallback_location: properties_path }
      format.json { render json: { currency: code } }
    end
  end
end
