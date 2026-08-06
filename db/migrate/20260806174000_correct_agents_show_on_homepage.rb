# frozen_string_literal: true

class CorrectAgentsShowOnHomepage < ActiveRecord::Migration[8.0]
  def up
    Agent.reset_column_information
    Agent.where(name: "My Bunch of Keys").update_all(show_on_homepage: false)
    Agent.where.not(name: "My Bunch of Keys").update_all(show_on_homepage: true)
  end

  def down
    Agent.reset_column_information
    Agent.where(name: "My Bunch of Keys").update_all(show_on_homepage: true)
    Agent.where.not(name: "My Bunch of Keys").update_all(show_on_homepage: false)
  end
end
