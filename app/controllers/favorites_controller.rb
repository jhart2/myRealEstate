class FavoritesController < ApplicationController
  def index
    @properties = current_user.favorited_properties.includes(:agent).order("favorites.created_at DESC")
  end

  def create
    property = Property.active.find_by!(slug: params[:property_id])
    current_user.favorites.find_or_create_by!(property: property)
    redirect_back fallback_location: property_path(property), notice: "Saved to favorites."
  end

  def destroy
    property = Property.find_by!(slug: params[:property_id])
    current_user.favorites.where(property: property).destroy_all
    redirect_back fallback_location: favorites_path, notice: "Removed from favorites."
  end
end
