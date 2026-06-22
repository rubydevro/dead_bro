# frozen_string_literal: true

DeadBro.configure do |cfg|
  cfg.api_key = ENV["DEAD_BRO_API_KEY"]
end

# Optional: flame-graph / call-stack profiling.
# DeadBro can capture a sampled call-stack profile per request using the
# `stackprof` gem. It is an optional, Linux-only dependency — add it to your
# Gemfile to enable profiling:
#
#   gem "stackprof", require: false
#
# Profiling stays off until enabled from the DeadBro dashboard (it ships a low,
# remotely-managed sample rate), and is a silent no-op on platforms where
# stackprof is unavailable (e.g. macOS development).
