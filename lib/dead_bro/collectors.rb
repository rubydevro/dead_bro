#!/usr/bin/env ruby
# frozen_string_literal: true

module DeadBro
  module Collectors
    autoload :Jobs,        "dead_bro/collectors/jobs"
    autoload :Database,    "dead_bro/collectors/database"
    autoload :ProcessInfo, "dead_bro/collectors/process_info"
    autoload :System,      "dead_bro/collectors/system"
    autoload :Filesystem,  "dead_bro/collectors/filesystem"
    autoload :Network,     "dead_bro/collectors/network"
    autoload :SampleStore, "dead_bro/collectors/sample_store"
  end
end

