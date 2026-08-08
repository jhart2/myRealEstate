ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "active_job/test_helper"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

    # Single-process for this small suite (sqlite).
  end
end
