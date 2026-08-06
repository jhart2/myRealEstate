# frozen_string_literal: true

class HideAllAgentsFromHomepage < ActiveRecord::Migration[8.1]
  def up
    Agent.update_all(show_on_homepage: false)
  end

  def down
    # Intentionally blank — previous homepage picks were environment-specific.
  end
end
