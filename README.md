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
- **Durability**: if Celerbrake is unreachable, failed batches are spooled to
  disk and replayed on later ticks. The spool is bounded (oldest dropped when
  full) and written atomically. Each tailed log has a persistent cursor, so a
  restart resumes where the last process stopped and a rotation never skips
  the end of the old file or the head of the new one. A backend outage never
  blocks your app.
- **Failure handling**: a batch the server can never accept does not block the
  ones behind it. 413 splits the batch (a single oversized item is
  quarantined), 400/422 quarantines it with the reason, 401/403 keeps spooling
  and reports the auth problem once, and 429/5xx/network errors spool and wait
  (Retry-After when the server sends one, otherwise exponential backoff with
  jitter, 1s to 5 min). Replay has a per-tick budget so fresh collection keeps
  flowing while a backlog drains.
- **Self-reporting**: the agent ships its own health every tick:
  `celerbrake_agent_dropped_batches_total` (batches lost to a full buffer: if
  this moves, you lost data and should know), `celerbrake_agent_quarantined_batches_total`
  (batches the server refused for good), `celerbrake_agent_auth_failures_total`
  (requests refused with 401/403), `celerbrake_agent_buffer_bytes` (the
  backlog; growing = Celerbrake unreachable) and `celerbrake_agent_cursor_lag_bytes{path}`
  (log bytes not read yet). They chart in the Metrics tab like any app metric.

All of it authenticates with your project id + key — the same wiring as error
reporting.

## Usage

```bash
celerbrake-agent --config celerbrake-agent.yml        # run the loop
celerbrake-agent --config celerbrake-agent.yml --once # one scrape+push (testing the metrics path)
```

Run it as its own process: a `Procfile` line in dev, and in production a
container alongside the app (on the Nanza platform, a Kamal accessory running
the app's own image, sharing the app's log volume).

> **`host` is required; the agent has no default.** It comes from the config
> file or from `CELERBRAKE_HOST`, and the agent refuses to start without it.
> The example below used to show `https://api.celerbrake.com`, which **no longer
> resolves**. That host is still hardcoded as the default inside the
> `celerbrake-ruby` notifier gem, which is a separate change (it means a
> lockfile bump and a redeploy for every app on the fleet), so do not copy it
> from there either.

## Config (`celerbrake-agent.yml`)

```yaml
celerbrake:
  host: https://celerbrake.com       # your Celerbrake instance (required)
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
  max_bytes: 100000000               # whole spool; oldest batches dropped past this
  max_batch_bytes: 4194304           # one batch (request and spool file); bigger ones are split
  quarantine_max_bytes: 10000000     # cap of <dir>/quarantine (batches the server refused for good)
  replay:                            # per-tick replay budget, so fresh data keeps flowing
    max_batches: 50
    max_bytes: 33554432
    max_seconds: 10
state:
  dir: tmp/celerbrake-agent/state    # log cursors (cursor.json); default <buffer.dir>/state
```

`CELERBRAKE_HOST`, `CELERBRAKE_PROJECT_ID`, and `CELERBRAKE_PROJECT_KEY` env vars
override the file (handy in containers).

Every key except `celerbrake.*` is optional, and unknown keys are ignored. Put
`buffer.dir` and `state.dir` on a persistent volume: the cursor is what lets a
restarted agent resume instead of skipping lines.

Notes:
- **First run**: with no saved cursor for a file the tailer starts at the
  **end** (it ships new lines, not the historical log) and saves that position.
  From then on it resumes from the cursor, so lines written while the agent was
  down are shipped. A log file that did not exist yet when the agent started is
  shipped from its first line. With `--once`, the first run records the cursor
  and the next `--once` ships what was appended in between.
- **Rotation**: rename rotation (a new inode at the path) finishes the old file
  before reading the new one from byte 0, also when it happened while the agent
  was down and the old file is still next to the log under a rotated name.
  In-place truncation (logrotate `copytruncate`) restarts at byte 0.
- **Delivery is at least once**: the cursor is committed only after a batch is
  delivered or spooled. Every log event carries an `event_id`
  (`<device>:<inode>:<byte offset>`) so a replayed duplicate can be identified.
- **Quarantine**: refused batches land in `<buffer.dir>/quarantine/` as JSON
  with `reason` (`too-large`, `item-too-large`, `invalid`, `corrupt`,
  `unknown-kind`), `detail` and, when they fit the cap, the items.
- Non-JSON lines are forwarded as raw events rather than dropped.

## Development

```bash
bundle install
bundle exec rspec
```
