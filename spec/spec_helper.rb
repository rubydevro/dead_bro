# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_filter "/.bundle/"
end

# Load ActiveSupport::Notifications for testing
begin
  require "active_support"
  require "active_support/notifications"
rescue LoadError
  # ActiveSupport not available
end

require "dead_bro"
require "net/http"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
