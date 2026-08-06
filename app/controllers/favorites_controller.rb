class FavoritesController < ApplicationController
  def index
    @properties = current_user.favorited_properties.includes(:agent).order("favorites.created_at DESC")
  end

  def create
    property = Property.active.find_by!(slug: params[:property_id])
    current_user.favorites.find_or_create_by!(property: property)
    respond_after_change(property, notice: "Saved to favorites.")
  end

  def destroy
    property = Property.find_by!(slug: params[:property_id])
    current_user.favorites.where(property: property).destroy_all
    respond_after_change(property, notice: "Removed from favorites.", fallback: favorites_path)
  end

  private

  def respond_after_change(property, notice:, fallback: nil)
    if lightbox_source?
      render turbo_stream: turbo_stream.replace(
        helpers.dom_id(property, :lightbox_favorite),
        partial: "properties/lightbox_favorite",
        locals: { property: property }
      )
    else
      redirect_back fallback_location: fallback || property_path(property), notice: notice
    end
  end

  def lightbox_source?
    params[:source].to_s == "lightbox"
  end
end
