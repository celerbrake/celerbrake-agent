require 'time'

module Celerbrake
  module Agent
    # The run loop. On each tick it:
    #   1. drains the disk buffer (replays batches that failed on earlier ticks),
    #   2. scrapes each metrics target -> pushes the samples,
    #   3. reads new log lines from each tailed file -> pushes the events.
    # Any push failure (network error or non-2xx) is caught and the batch is
    # written to the disk buffer for replay, so a Celerbrake outage never drops
    # data and never crashes the agent.
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
        @tailers = config.log_paths.map { |path| LogTailer.new(path: path, logger: logger) }
        @buffer  = Buffer.new(dir: config.buffer_dir, logger: logger, max_bytes: config.buffer_max_bytes)
        @stop = false
      end

      # One full cycle. Returns { metrics:, logs:, replayed: } counts.
      def run_once(now: Time.now)
        replayed = drain_buffer
        ts = now.utc.iso8601

        metrics = 0
        @scrapers.each do |scraper|
          text = scraper.scrape
          next unless text

          samples = PrometheusParser.parse(text).map { |s| s.merge(ts: ts) }
          metrics += deliver(:metrics, samples) unless samples.empty?
        end

        logs = 0
        @tailers.each do |tailer|
          events = tailer.read_new
          logs += deliver(:logs, events) unless events.empty?
        end

        if (metrics + logs + replayed).positive?
          extra = replayed.positive? ? " (+#{replayed} replayed from buffer)" : ''
          @logger.info("celerbrake-agent: pushed #{metrics} samples, #{logs} log events#{extra}")
        end

        { metrics: metrics, logs: logs, replayed: replayed }
      end

      def run
        trap_signals
        @logger.info(
          "celerbrake-agent: starting (interval #{@config.interval}s, " \
          "#{@scrapers.size} scrape target(s), #{@tailers.size} log file(s))"
        )
        loop do
          run_once
          break if @stop

          sleep_interval
          break if @stop
        end
        @logger.info('celerbrake-agent: stopped')
      end

      def stop
        @stop = true
      end

      private

      # Push a batch; on failure, buffer it for replay. Returns the number of
      # items delivered (0 if it was buffered).
      def deliver(kind, items)
        push(kind, items)
        items.size
      rescue Client::Error => e
        @logger.error("#{e.message} — buffering #{items.size} #{kind}")
        @buffer.enqueue(kind, items)
        0
      end

      def push(kind, items)
        kind.to_sym == :metrics ? @client.push_metrics(items) : @client.push_logs(items)
      end

      # Replay buffered batches oldest-first; stop at the first failure (the
      # backend is still down — leave the rest for the next tick). Returns the
      # number of items successfully replayed.
      def drain_buffer
        replayed = 0
        @buffer.each_batch do |kind, items, path|
          begin
            push(kind, items)
            @buffer.delete(path)
            replayed += items.size
          rescue Client::Error => e
            @logger.warn("celerbrake-agent: buffer replay still failing (#{e.message}); will retry next tick")
            break
          end
        end
        replayed
      end

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
