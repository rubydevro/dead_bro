# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# standard requires Ruby >= 3.0 and is omitted from the Gemfile on 2.7 runs,
# so load its rake task only when the gem is actually available.
standard_available =
  begin
    require "standard/rake"
    true
  rescue LoadError
    false
  end

task default: standard_available ? %i[spec standard] : %i[spec]
