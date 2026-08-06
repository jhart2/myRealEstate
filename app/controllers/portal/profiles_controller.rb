module Portal
  class ProfilesController < BaseController
    def edit
    end

    def update
      if agent.update(profile_params)
        redirect_to edit_portal_profile_path, notice: "Profile updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def profile_params
      params.require(:agent).permit(
        :name, :title, :bio, :email, :phone, :image, :remove_image, :sales_volume, :years_experience
      )
    end
  end
end
