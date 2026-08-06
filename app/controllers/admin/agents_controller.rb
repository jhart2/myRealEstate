module Admin
  class AgentsController < BaseController
    before_action :set_agent, only: %i[edit update destroy]

    def index
      @agents = Agent.order(:name)
    end

    def new
      @agent = Agent.new(active: true)
    end

    def create
      @agent = Agent.new(agent_params)
      if @agent.save
        redirect_to admin_agents_path, notice: "Agent created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @agent.update(agent_params)
        redirect_to admin_agents_path, notice: "Agent updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @agent.destroy
      redirect_to admin_agents_path, notice: "Agent deleted."
    end

    private

    def set_agent
      @agent = Agent.find(params[:id])
    end

    def agent_params
      params.require(:agent).permit(:name, :title, :bio, :email, :phone, :image, :remove_image, :sales_volume, :years_experience, :active, :show_on_homepage, :user_id)
    end
  end
end
