module Portal
  class PropertiesController < BaseController
    before_action :set_property, only: %i[edit update destroy]

    def index
      @properties = agent.properties.order(updated_at: :desc)
    end

    def new
      @property = agent.properties.build(status: "active", tag: "sale")
    end

    def create
      @property = agent.properties.build(property_params)
      if @property.save
        redirect_to portal_properties_path, notice: "Listing published."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @property.update(property_params)
        redirect_to portal_properties_path, notice: "Listing updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @property.destroy
      redirect_to portal_properties_path, notice: "Listing removed."
    end

    private

    def set_property
      @property = agent.properties.find_by!(slug: params[:id])
    end

    def property_params
      params.require(:property).permit(
        :title, :tag, :property_type, :status, :address, :city, :state, :zip,
        :price_cents, :beds, :baths, :sqft, :lot_sqft, :acres, :description, :image, :remove_image, :featured,
        :latitude, :longitude
      )
    end
  end
end
