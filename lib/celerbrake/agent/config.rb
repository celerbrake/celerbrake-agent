require 'yaml'

module Celerbrake
  module Agent
    # Agent configuration. Loaded from a YAML file; a few key fields can be
    # overridden by env vars (handy for containers). Shape:
    #
    #   celerbrake:
    #     host: https://api.celerbrake.com
    #     project_id: 123
    #     project_key: "…"
    #   scrape:
    #     - url: http://localhost:4000/api/metrics
    #       token: "<metrics_scrape_token>"
    #   logs:
    #     - path: log/production.log
    #   flush:
    #     interval: 15
    #   buffer:
    #     dir: tmp/celerbrake-agent
    #     max_bytes: 100000000
    class Config
      DEFAULT_INTERVAL = 15
      DEFAULT_BUFFER_DIR = 'tmp/celerbrake-agent'.freeze
      DEFAULT_BUFFER_MAX_BYTES = 100_000_000

      attr_reader :host, :project_id, :project_key, :scrape_targets, :log_paths,
                  :interval, :buffer_dir, :buffer_max_bytes, :open_timeout, :read_timeout

      def initialize(host:, project_id:, project_key:,
                     scrape_targets: [], log_paths: [],
                     interval: DEFAULT_INTERVAL,
                     buffer_dir: DEFAULT_BUFFER_DIR, buffer_max_bytes: DEFAULT_BUFFER_MAX_BYTES,
                     open_timeout: 5, read_timeout: 10)
        @host = host
        @project_id = project_id
        @project_key = project_key
        @scrape_targets = scrape_targets
        @log_paths = log_paths
        @interval = interval
        @buffer_dir = buffer_dir
        @buffer_max_bytes = buffer_max_bytes
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def self.load(path)
        raw = YAML.safe_load(File.read(path)) || {}
        cb = raw['celerbrake'] || {}
        buffer = raw['buffer'] || {}

        new(
          host:             ENV['CELERBRAKE_HOST']        || cb['host'],
          project_id:       ENV['CELERBRAKE_PROJECT_ID']  || cb['project_id'],
          project_key:      ENV['CELERBRAKE_PROJECT_KEY'] || cb['project_key'],
          scrape_targets:   Array(raw['scrape']).map { |t| { url: t['url'], token: t['token'], interval: t['interval'] } },
          log_paths:        Array(raw['logs']).filter_map { |l| l['path'] },
          interval:         (raw.dig('flush', 'interval') || DEFAULT_INTERVAL).to_i,
          buffer_dir:       buffer['dir'] || DEFAULT_BUFFER_DIR,
          buffer_max_bytes: (buffer['max_bytes'] || DEFAULT_BUFFER_MAX_BYTES).to_i
        )
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
