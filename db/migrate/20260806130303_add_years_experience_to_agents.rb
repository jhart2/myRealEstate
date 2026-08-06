class AddYearsExperienceToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :years_experience, :integer
  end
end
