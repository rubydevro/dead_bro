# frozen_string_literal: true

require "rails/generators"

module DeadBro
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a DeadBro initializer in config/initializers/dead_bro.rb"

      def create_initializer
        template "dead_bro.rb", "config/initializers/dead_bro.rb"
      end
    end
  end
end
