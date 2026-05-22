# celerbrake-agent

A small, standalone collector that runs **alongside** your app and ships its
telemetry to a [Celerbrake](https://github.com/celerbrake/celerbrake) instance —
keeping your app's request path free of any telemetry network I/O (the
Datadog-agent model).

What it does today (M1 / R1):

- **Scrapes** your app's local Prometheus `/api/metrics` endpoint on an interval,
  parses the exposition, and **pushes** the samples to Celerbrake
  (`POST /api/v3/projects/:id/metrics`), authenticated with your project id + key.

Coming next: tailing the JSON log → `…/logs`, and disk-buffering + retry so a
Celerbrake outage never loses data (see the Celerbrake repo's
`docs/APM_ROADMAP.md`).

## Usage

```bash
celerbrake-agent --config celerbrake-agent.yml      # run the loop
celerbrake-agent --config celerbrake-agent.yml --once   # one scrape+push (testing)
```

## Config (`celerbrake-agent.yml`)

```yaml
celerbrake:
  host: https://api.celerbrake.com   # your Celerbrake instance
  project_id: 123                    # from /admin/projects/:id
  project_key: "your-project-key"
scrape:
  - url: http://localhost:4000/api/metrics
    token: "your-metrics_scrape_token"   # the app's metrics_scrape_token credential
flush:
  interval: 15                       # seconds between scrapes
```

`CELERBRAKE_HOST`, `CELERBRAKE_PROJECT_ID`, and `CELERBRAKE_PROJECT_KEY` env vars
override the file (handy in containers).

## Development

```bash
bundle install
bundle exec rspec
```
