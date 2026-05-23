require 'celerbrake/agent/version'
require 'celerbrake/agent/config'
require 'celerbrake/agent/prometheus_parser'
require 'celerbrake/agent/client'
require 'celerbrake/agent/scraper'
require 'celerbrake/agent/log_tailer'
require 'celerbrake/agent/buffer'
require 'celerbrake/agent/runner'

# celerbrake-agent — a separate collector process that pulls an app's standard
# telemetry outputs (the Prometheus /api/metrics endpoint and the JSON log) and
# pushes them to a Celerbrake instance, buffering to disk and retrying so a
# backend outage never loses data. See README.md and, in the Celerbrake repo,
# docs/APM_ROADMAP.md (R1).
module Celerbrake
  module Agent
  end
end
