require 'time'

module Celerbrake
  module Agent
    # The run loop: on each tick, scrape every configured target, parse the
    # exposition into samples, stamp them with the scrape time, and push them to
    # Celerbrake. A failed push is logged and dropped for now — disk buffering +
    # retry is the next hardening pass (see docs/APM_ROADMAP.md R1).
    class Runner
      def initialize(config:, logger:)
        @config = config
        @logger = logger
        @client = Client.new(
          host:         config.host,
          project_id:   config.project_id,
          project_key:  config.project_key,
          logger:       logger,
          open_timeout: config.open_timeout,
          read_timeout: config.read_timeout
        )
        @scrapers = config.scrape_targets.map do |t|
          Scraper.new(url: t[:url], token: t[:token], logger: logger,
                      open_timeout: config.open_timeout, read_timeout: config.read_timeout)
        end
        @stop = false
      end

      # One scrape+push cycle across all targets. Returns the number of samples pushed.
      def run_once(now: Time.now)
        ts = now.utc.iso8601
        pushed = 0

        @scrapers.each do |scraper|
          text = scraper.scrape
          next unless text

          samples = PrometheusParser.parse(text).map { |s| s.merge(ts: ts) }
          next if samples.empty?

          begin
            pushed += @client.push_metrics(samples)
          rescue Client::Error => e
            @logger.error(e.message)
          end
        end

        @logger.info("celerbrake-agent: pushed #{pushed} samples") if pushed.positive?
        pushed
      end

      def run
        trap_signals
        @logger.info("celerbrake-agent: starting (interval #{@config.interval}s, #{@scrapers.size} target(s))")
        run_once until (sleep_interval; @stop)
        @logger.info('celerbrake-agent: stopped')
      end

      def stop
        @stop = true
      end

      private

      def trap_signals
        %w[INT TERM].each { |sig| Signal.trap(sig) { @stop = true } }
      end

      # Sleep in 1s slices so a stop signal is honored promptly.
      def sleep_interval
        @config.interval.to_i.times do
          break if @stop

          sleep 1
        end
      end
    end
  end
end
