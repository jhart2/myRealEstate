module Admin
  class PropertiesController < BaseController
    before_action :set_property, only: %i[edit update destroy]

    def index
      scope = Property.includes(:agent)

      if params[:q].present?
        q = "%#{Property.sanitize_sql_like(params[:q].to_s.strip)}%"
        scope = scope.where(
          "title LIKE :q OR address LIKE :q OR city LIKE :q OR property_type LIKE :q",
          q: q
        )
      end

      if params[:status].present? && Property::STATUSES.include?(params[:status])
        scope = scope.where(status: params[:status])
      end

      if params[:tag].present? && Property::TAGS.include?(params[:tag])
        scope = scope.where(tag: params[:tag])
      end

      scope = case params[:sort]
      when "price_asc" then scope.order(price_cents: :asc)
      when "price_desc" then scope.order(price_cents: :desc)
      when "title" then scope.order(Arel.sql("LOWER(title) ASC"))
      when "oldest" then scope.order(created_at: :asc)
      else scope.order(created_at: :desc)
      end

      @per_page = 12
      @total_count = scope.count
      @page = [ params[:page].to_i, 1 ].max
      @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
      @page = [ @page, @total_pages ].min
      @properties = scope.offset((@page - 1) * @per_page).limit(@per_page)
      @range_from = @total_count.zero? ? 0 : ((@page - 1) * @per_page) + 1
      @range_to = [ ((@page - 1) * @per_page) + @properties.size, @total_count ].min
    end

    def new
      @property = Property.new(status: "active", tag: "sale")
      @agents = Agent.active.order(:name)
    end

    def create
      @property = Property.new
      @agents = Agent.active.order(:name)
      assign_property_attrs(@property)
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
      assign_property_attrs(@property)
      if @property.save
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

    def assign_property_attrs(property)
      raw = params.require(:property)
      property.assign_attributes(property_params.except(:image_url, :image_urls, :gallery_sync))
      apply_gallery!(property, raw) if raw[:gallery_sync].to_s == "1"
    end

    def apply_gallery!(property, raw)
      urls = Array(raw[:image_urls]).map { |u| u.to_s.strip }.reject(&:blank?).uniq
      cover = raw[:image_url].to_s.strip.presence
      cover = urls.first if cover.blank? || (urls.any? && !urls.include?(cover))
      urls = ([ cover ] + urls).compact.uniq if cover
      property.image_urls = urls
      property.image_url = cover
      # Prefer URL cover over a previously uploaded ActiveStorage file unless uploading a new file.
      if cover.present? && property.image.attached? && raw[:image].blank?
        property.remove_image = "1"
      end
    end

    def property_params
      params.require(:property).permit(
        :title, :tag, :property_type, :status, :address, :city, :state, :zip,
        :price_dollars, :beds, :baths, :sqft, :lot_sqft, :acres, :description, :image, :remove_image, :featured, :agent_id,
        :latitude, :longitude, :image_url, :gallery_sync, image_urls: []
      )
    end
  end
end
