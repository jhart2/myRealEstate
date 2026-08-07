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
    respond_to do |format|
      format.turbo_stream { render turbo_stream: favorite_streams(property) }
      format.html do
        redirect_back fallback_location: fallback || property_path(property), notice: notice
      end
    end
  end

  def favorite_streams(property)
    streams = []

    if lightbox_source?
      streams << turbo_stream.replace(
        helpers.dom_id(property, :lightbox_favorite),
        partial: "properties/lightbox_favorite",
        locals: { property: property }
      )
    else
      streams << turbo_stream.replace(
        helpers.dom_id(property, :favorite_heart),
        partial: "properties/favorite_heart",
        locals: { property: property, variant: heart_variant }
      )
      # Keep lightbox heart in sync if that panel is open for the same listing.
      streams << turbo_stream.replace(
        helpers.dom_id(property, :lightbox_favorite),
        partial: "properties/lightbox_favorite",
        locals: { property: property }
      )
    end

    streams
  end

  def lightbox_source?
    params[:source].to_s == "lightbox"
  end

  def heart_variant
    params[:variant].to_s == "card" ? "card" : "carousel"
  end
end
