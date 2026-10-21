celerbrake-agent Changelog
==========================

Seeded on 2026-09-20 from this repository's git history, which starts at the
initial commit on 2026-05-22. The gem is git-sourced by the fleet rather than
published to RubyGems and carries no version tags, so the headings below are
the value of `Celerbrake::Agent::VERSION` at the time each change landed.

### master (unreleased)

- Nothing yet.

### v0.3.0 (2026-10-20)

Collector durability (platform review findings R04 and R05).

- Persistent log cursors: each tailed file's device, inode and byte offset are
  saved atomically to `state.dir/cursor.json` (default `<buffer.dir>/state`).
  Tail-from-end now applies only on the first installation; a restart resumes
  from the cursor, so lines written while the agent was down are no longer
  skipped. The cursor is committed only after the batch was delivered or
  spooled; when the spool cannot be written the lines are read again next tick.
- Rotation by inode: a renamed log is read to its end before the new file is
  read from byte 0, including a rotation that happened while the agent was down
  (the old file is found by inode next to the log). In-place truncation is
  caught by size and by a signature of the bytes before the offset, so a
  replacement larger than the old offset no longer loses its head.
- Log events carry `event_id` (`<device>:<inode>:<byte offset>`) so replay
  duplicates can be identified downstream.
- Classified client errors: `Client::TooLarge` (413, and the server's 422
  `batch-too-large`), `Invalid` (400, 422), `Unauthorized` (401, 403),
  `RateLimited` (429), `ServerError` (5xx and any other non-2xx) and `Transport`
  (network, timeout), all subclasses of `Client::Error` with `status` and
  `retry_after` (seconds or an HTTP-date). Messages keep their format.
- Delivery policy: 413 splits the batch down to single items and quarantines an
  item that is still too large; 400/422 quarantine the batch with the reason;
  401/403 spool and log once per state change; 429/5xx/network errors spool
  and wait for Retry-After or an exponential backoff with jitter (1s to 5 min)
  during which delivery goes straight to the spool. A permanently refused
  spooled batch is quarantined and replay continues with the next one.
- Replay budget per tick: `buffer.replay.max_batches` (50), `max_bytes`
  (32 MiB) and `max_seconds` (10), so fresh collection continues while a
  backlog drains.
- Buffer: atomic writes (temp file, fsync, rename; leftover temp files are
  swept on start); the incoming batch is accounted for before pruning, so the
  spool stays within `buffer.max_bytes`; `buffer.max_batch_bytes` (4 MiB)
  splits a large batch at enqueue; an unreadable batch is quarantined instead
  of deleted; `quarantine/` has its own cap (`buffer.quarantine_max_bytes`,
  10 MB) and keeps only the reason and item count for an entry too big for it.
- Self-metrics: `celerbrake_agent_quarantined_batches_total`,
  `celerbrake_agent_auth_failures_total` and
  `celerbrake_agent_cursor_lag_bytes{path}` join the dropped-batches and
  buffer-bytes series.
- Log lines no longer contain em dashes.

Also first released in v0.3.0 (landed while the version still read 0.2.0):

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
