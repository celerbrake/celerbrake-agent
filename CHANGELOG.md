celerbrake-agent Changelog
==========================

Seeded on 2026-09-20 from this repository's git history, which starts at the
initial commit on 2026-05-22. The gem is git-sourced by the fleet rather than
published to RubyGems and carries no version tags, so the headings below are
the value of `Celerbrake::Agent::VERSION` at the time each change landed.

### master (unreleased)

- CI: added a GitHub Actions workflow that runs the RSpec suite on Ruby 3.3 and
  3.4. This repository had no workflow at all, so nothing ran its 33 specs on a
  push or a pull request.
- Added this CHANGELOG.
- README: stopped pointing at `api.celerbrake.com`, which no longer resolves.

### v0.2.0 (2026-06-11)

- Agent self-metrics: the agent reports its own buffer drops and backlog as
  `celerbrake_agent_*` metrics, so telemetry that a Celerbrake outage pushed
  into the disk buffer is visible rather than silently absorbed.
- Removed the dead per-target interval setting.

### v0.1.0 (2026-05-22 to 2026-05-25)

- Initial release: a standalone collector process that scrapes an app's local
  Prometheus `/api/metrics` endpoint, tails its JSON logs, and pushes the
  telemetry to a Celerbrake instance, authenticated with the same project id
  and key as error reporting. The app's request path does no telemetry network
  I/O.
- Log tailing plus a disk buffer with retry, so telemetry survives a Celerbrake
  outage instead of being dropped (completes M1 / R1).
- Coerce payload strings to UTF-8 before `JSON.generate`, so one non-UTF-8 byte
  in a log line cannot kill a push.
- Sync `$stdout` so the agent's own INFO logs reach systemd promptly.
- Log tailer: parse the standard Ruby `Logger` prefix, lifting the level and
  timestamp off a plain line and keeping the JSON remainder's fields.
- Log tailer: strip tagged-logging brackets such as
  `[ActiveJob][JobClass][job_id]`, synthesize a readable message for structured
  lines that carry no `message` key, lift a UUID tag as the correlation id, and
  append the status to a failed job line (APM #6).
