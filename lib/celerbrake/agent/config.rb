require 'yaml'

module Celerbrake
  module Agent
    # Agent configuration. Loaded from a YAML file; a few key fields can be
    # overridden by env vars (handy for containers). Unknown keys are ignored.
    # Shape (every key below `celerbrake` is optional):
    #
    #   celerbrake:
    #     host: https://celerbrake.com
    #     project_id: 123
    #     project_key: "..."
    #   scrape:
    #     - url: http://localhost:4000/api/metrics
    #       token: "<metrics_scrape_token>"
    #   logs:
    #     - path: log/production.log
    #   flush:
    #     interval: 15
    #   buffer:
    #     dir: tmp/celerbrake-agent
    #     max_bytes: 100000000          # whole spool, oldest dropped past this
    #     max_batch_bytes: 4194304      # one batch (request and spool file)
    #     quarantine_max_bytes: 10000000
    #     replay:                       # per-tick replay budget
    #       max_batches: 50
    #       max_bytes: 33554432
    #       max_seconds: 10
    #   state:
    #     dir: tmp/celerbrake-agent/state   # default <buffer.dir>/state
    class Config
      DEFAULT_INTERVAL = 15
      DEFAULT_BUFFER_DIR = 'tmp/celerbrake-agent'.freeze
      DEFAULT_BUFFER_MAX_BYTES = 100_000_000
      DEFAULT_MAX_BATCH_BYTES = 4 * 1024 * 1024
      DEFAULT_QUARANTINE_MAX_BYTES = 10_000_000
      DEFAULT_REPLAY_MAX_BATCHES = 50
      DEFAULT_REPLAY_MAX_BYTES = 32 * 1024 * 1024
      DEFAULT_REPLAY_MAX_SECONDS = 10
      STATE_SUBDIR = 'state'.freeze

      attr_reader :host, :project_id, :project_key, :scrape_targets, :log_paths,
                  :interval, :buffer_dir, :buffer_max_bytes, :open_timeout, :read_timeout,
                  :state_dir, :buffer_max_batch_bytes, :quarantine_max_bytes,
                  :replay_max_batches, :replay_max_bytes, :replay_max_seconds

      def initialize(host:, project_id:, project_key:,
                     scrape_targets: [], log_paths: [],
                     interval: DEFAULT_INTERVAL,
                     buffer_dir: DEFAULT_BUFFER_DIR, buffer_max_bytes: DEFAULT_BUFFER_MAX_BYTES,
                     buffer_max_batch_bytes: DEFAULT_MAX_BATCH_BYTES,
                     quarantine_max_bytes: DEFAULT_QUARANTINE_MAX_BYTES,
                     replay_max_batches: DEFAULT_REPLAY_MAX_BATCHES,
                     replay_max_bytes: DEFAULT_REPLAY_MAX_BYTES,
                     replay_max_seconds: DEFAULT_REPLAY_MAX_SECONDS,
                     state_dir: nil,
                     open_timeout: 5, read_timeout: 10)
        @host = host
        @project_id = project_id
        @project_key = project_key
        @scrape_targets = scrape_targets
        @log_paths = log_paths
        @interval = interval
        @buffer_dir = buffer_dir
        @buffer_max_bytes = buffer_max_bytes
        @buffer_max_batch_bytes = buffer_max_batch_bytes
        @quarantine_max_bytes = quarantine_max_bytes
        @replay_max_batches = replay_max_batches
        @replay_max_bytes = replay_max_bytes
        @replay_max_seconds = replay_max_seconds
        # Older config files have no `state` key: keep the cursor next to the
        # spool, which is already on the persistent volume.
        @state_dir = state_dir.to_s.empty? ? File.join(buffer_dir, STATE_SUBDIR) : state_dir
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def self.load(path)
        raw = YAML.safe_load(File.read(path)) || {}
        cb = raw['celerbrake'] || {}
        buffer = hash_at(raw, 'buffer')
        replay = hash_at(buffer, 'replay')
        state = hash_at(raw, 'state')

        new(
          host:             ENV['CELERBRAKE_HOST']        || cb['host'],
          project_id:       ENV['CELERBRAKE_PROJECT_ID']  || cb['project_id'],
          project_key:      ENV['CELERBRAKE_PROJECT_KEY'] || cb['project_key'],
          # NOTE: a per-target `interval` key used to be parsed here but was
          # never honored (one global flush interval drives every target).
          # Removed rather than implemented: dead config that LOOKS like a
          # knob is worse than no knob. Use flush.interval.
          scrape_targets:   Array(raw['scrape']).map { |t| { url: t['url'], token: t['token'] } },
          log_paths:        Array(raw['logs']).filter_map { |l| l['path'] },
          interval:         (raw.dig('flush', 'interval') || DEFAULT_INTERVAL).to_i,
          buffer_dir:       buffer['dir'] || DEFAULT_BUFFER_DIR,
          buffer_max_bytes: (buffer['max_bytes'] || DEFAULT_BUFFER_MAX_BYTES).to_i,
          buffer_max_batch_bytes: (buffer['max_batch_bytes'] || DEFAULT_MAX_BATCH_BYTES).to_i,
          quarantine_max_bytes:   (buffer['quarantine_max_bytes'] || DEFAULT_QUARANTINE_MAX_BYTES).to_i,
          replay_max_batches:     (replay['max_batches'] || DEFAULT_REPLAY_MAX_BATCHES).to_i,
          replay_max_bytes:       (replay['max_bytes'] || DEFAULT_REPLAY_MAX_BYTES).to_i,
          replay_max_seconds:     (replay['max_seconds'] || DEFAULT_REPLAY_MAX_SECONDS).to_f,
          state_dir:              state['dir']
        )
      end

      def self.hash_at(hash, key)
        value = hash.is_a?(Hash) ? hash[key] : nil
        value.is_a?(Hash) ? value : {}
      end

      # @return [self]
      def validate!
        missing = []
        missing << 'host'        if host.to_s.empty?
        missing << 'project_id'  if project_id.to_s.empty?
        missing << 'project_key' if project_key.to_s.empty?
        unless missing.empty?
          raise ArgumentError, "celerbrake-agent: missing required config: #{missing.join(', ')}"
        end

        self
      end
    end
  end
end
