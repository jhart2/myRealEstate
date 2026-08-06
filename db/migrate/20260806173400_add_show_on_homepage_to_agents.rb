class AddShowOnHomepageToAgents < ActiveRecord::Migration[8.0]
  def up
    add_column :agents, :show_on_homepage, :boolean, default: false, null: false

    Agent.reset_column_information
    Agent.where(name: "My Bunch of Keys").update_all(show_on_homepage: true)
  end

  def down
    remove_column :agents, :show_on_homepage
  end
end
