module Admin
  class PropertiesController < BaseController
    before_action :set_property, only: %i[edit update destroy]

    def index
      @properties = Property.includes(:agent).order(created_at: :desc)
    end

    def new
      @property = Property.new(status: "active", tag: "sale")
      @agents = Agent.active.order(:name)
    end

    def create
      @property = Property.new(property_params)
      @agents = Agent.active.order(:name)
      if @property.save
        redirect_to admin_properties_path, notice: "Property created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @agents = Agent.active.order(:name)
    end

    def update
      @agents = Agent.active.order(:name)
      if @property.update(property_params)
        redirect_to admin_properties_path, notice: "Property updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @property.destroy
      redirect_to admin_properties_path, notice: "Property deleted."
    end

    private

    def set_property
      @property = Property.find_by!(slug: params[:id])
    end

    def property_params
      params.require(:property).permit(
        :title, :tag, :property_type, :status, :address, :city, :state, :zip,
        :price_cents, :beds, :baths, :sqft, :lot_sqft, :acres, :description, :image, :remove_image, :featured, :agent_id,
        :latitude, :longitude
      )
    end
  end
end
