# celerbrake-agent

A small, standalone collector that runs **alongside** your app and ships its
telemetry to a [Celerbrake](https://github.com/celerbrake/celerbrake) instance —
keeping your app's request path free of any telemetry network I/O (the
Datadog-agent model).

What it does:

- **Metrics** — scrapes your app's local Prometheus `/api/metrics` endpoint on
  an interval, parses the exposition, and pushes the samples to Celerbrake
  (`POST /api/v3/projects/:id/metrics`).
- **Logs** — tails your app's JSON log file and pushes the events to Celerbrake
  (`POST /api/v3/projects/:id/logs`), correlating by `request_id`.
- **Durability** — if Celerbrake is unreachable, failed batches are buffered to
  disk and replayed on later ticks (bounded; oldest dropped when full). A backend
  outage never blocks your app or loses data on the agent side.

All of it authenticates with your project id + key — the same wiring as error
reporting.

## Usage

```bash
celerbrake-agent --config celerbrake-agent.yml        # run the loop
celerbrake-agent --config celerbrake-agent.yml --once # one scrape+push (testing the metrics path)
```

Run it as its own process (a `Procfile` line in dev, a systemd unit in prod).

## Config (`celerbrake-agent.yml`)

```yaml
celerbrake:
  host: https://api.celerbrake.com   # your Celerbrake instance
  project_id: 123                    # from /admin/projects/:id
  project_key: "your-project-key"
scrape:
  - url: http://localhost:4000/api/metrics
    token: "your-metrics_scrape_token"   # the app's metrics_scrape_token credential (omit if unset)
logs:
  - path: log/production.log         # JSON lines (lograge); tailed for new entries
flush:
  interval: 15                       # seconds between ticks
buffer:
  dir: tmp/celerbrake-agent          # where failed batches are spooled
  max_bytes: 100000000               # cap; oldest batches dropped past this
```

`CELERBRAKE_HOST`, `CELERBRAKE_PROJECT_ID`, and `CELERBRAKE_PROJECT_KEY` env vars
override the file (handy in containers).

Notes:
- The log tailer starts at the **end** of the file (it ships new lines, not the
  historical log), so `--once` exercises the metrics path; logs flow when run as
  a daemon. Non-JSON lines are forwarded as raw events rather than dropped.

## Development

```bash
bundle install
bundle exec rspec
```
