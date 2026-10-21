require 'time'

module Celerbrake
  module Agent
    # The run loop. On each tick it:
    #   1. replays spooled batches (oldest first, within a per-tick budget),
    #   2. scrapes each metrics target and pushes the samples,
    #   3. reads new log lines from each tailed file and pushes the events,
    #      committing each file's cursor once its events are delivered or spooled,
    #   4. pushes the agent's own health metrics.
    #
    # Delivery policy, by Client error class:
    #   * TooLarge: split the batch in halves and retry each, down to single
    #     items; a single item that is still too large is quarantined.
    #   * Invalid: quarantine the batch with the reason; never spooled.
    #   * Unauthorized: spool (the key may be fixed later) and enter the
    #     auth-failing state: logged at ERROR once per state change and counted
    #     in celerbrake_agent_auth_failures_total.
    #   * RateLimited, ServerError, Transport: spool, then wait: Retry-After when
    #     the server sent one, otherwise exponential backoff with jitter
    #     (1s to 5min). While waiting, deliveries go straight to the spool and
    #     replay is skipped.
    # A permanent failure while replaying quarantines that batch and continues
    # with the next one; a transient failure stops the replay for this tick.
    class Runner
      KINDS = %w[metrics logs].freeze
      MIN_BACKOFF = 1.0
      MAX_BACKOFF = 300.0
      # Requests one batch may cost while being split on 413. Isolating a few
      # oversized items in a 2,000-line batch takes ~25; a proxy that answers
      # 413 to everything must not turn one tick into thousands of requests
      # (or quarantine everything), so past this the rest is spooled and the
      # runner backs off.
      MAX_SPLIT_REQUESTS = 64

      # Result of sending one batch, possibly split into several requests.
      class Attempt
        attr_accessor :delivered, :error, :requests
        attr_reader :pending, :quarantine

        def initialize
          @delivered = 0
          @requests = 0
          @pending = []     # item slices still to deliver (transient failure)
          @quarantine = []  # [items, reason, error]
          @error = nil      # the transient/auth error that stopped delivery
        end
      end

      def initialize(config:, logger:, clock: nil, rng: nil)
        @config = config
        @logger = logger
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @rng = rng || Random.new
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
        @cursors = config.log_paths.empty? ? nil : CursorStore.new(dir: config.state_dir, logger: logger)
        @tailers = config.log_paths.map { |path| LogTailer.new(path: path, logger: logger, cursor_store: @cursors) }
        @buffer  = Buffer.new(dir: config.buffer_dir, logger: logger, max_bytes: config.buffer_max_bytes,
                              max_batch_bytes: config.buffer_max_batch_bytes,
                              quarantine_max_bytes: config.quarantine_max_bytes)
        @stop = false
        @retry_at = nil
        @consecutive_failures = 0
        @auth_failing = false
        @auth_failures = 0
      end

      attr_reader :auth_failures

      # One full cycle. Returns { metrics:, logs:, replayed: } counts.
      def run_once(now: Time.now)
        replayed = drain_buffer
        ts = now.utc.iso8601

        metrics = 0
        @scrapers.each do |scraper|
          text = scraper.scrape
          next unless text

          samples = PrometheusParser.parse(text).map { |s| s.merge(ts: ts) }
          metrics += deliver(:metrics, samples).first unless samples.empty?
        end

        logs = 0
        @tailers.each do |tailer|
          events = tailer.read_new
          delivered, durable = events.empty? ? [0, true] : deliver(:logs, events)
          logs += delivered
          # Advance the cursor only once the lines are delivered or on disk;
          # otherwise the next tick reads them again (the log file is the
          # spool of last resort when the buffer cannot be written).
          durable ? tailer.commit! : tailer.rewind!
        end

        # The agent's own health, as first-class metrics. Emitted every tick (0
        # when healthy) so the series exists before trouble starts; if the push
        # fails these get buffered and replayed like everything else,
        # preserving the outage record.
        metrics += deliver(:metrics, self_metrics(ts)).first

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

      # The agent reporting on itself. Counters reset on agent restart; the
      # server's rollups are reset-aware.
      #   dropped_batches_total      batches lost to a full buffer (data loss)
      #   quarantined_batches_total  batches the server can never accept
      #   auth_failures_total        requests refused with 401/403
      #   buffer_bytes               spool backlog (growing = Celerbrake unreachable)
      #   cursor_lag_bytes{path}     log bytes written but not read yet
      def self_metrics(ts)
        samples = [
          { name: 'celerbrake_agent_dropped_batches_total', type: 'counter',
            labels: {}, value: @buffer.dropped.to_f, ts: ts },
          { name: 'celerbrake_agent_quarantined_batches_total', type: 'counter',
            labels: {}, value: @buffer.quarantined.to_f, ts: ts },
          { name: 'celerbrake_agent_auth_failures_total', type: 'counter',
            labels: {}, value: @auth_failures.to_f, ts: ts },
          { name: 'celerbrake_agent_buffer_bytes', type: 'gauge',
            labels: {}, value: @buffer.size_bytes.to_f, ts: ts }
        ]
        @tailers.each do |tailer|
          samples << { name: 'celerbrake_agent_cursor_lag_bytes', type: 'gauge',
                       labels: { 'path' => tailer.to_s }, value: tailer.lag_bytes.to_f, ts: ts }
        end
        samples
      end

      # Push a fresh batch. Returns [delivered_count, durable]: durable is true
      # when every item was delivered, spooled or deliberately quarantined, false
      # when some could not be written anywhere (the caller may retry them).
      def deliver(kind, items)
        return [0, true] if items.empty?

        if waiting?
          return [0, @buffer.enqueue(kind, items)]
        end

        slices, oversized = @buffer.slice(kind, items)
        oversized.each do |item|
          @buffer.quarantine(kind, [item], reason: 'item-too-large',
                                           detail: "one item is larger than max_batch_bytes (#{@buffer.max_batch_bytes}B)")
        end
        attempt = Attempt.new
        slices.each { |slice| send_tree(kind, slice, attempt) }
        quarantine_all(kind, attempt)

        durable = attempt.pending.map { |piece| @buffer.enqueue(kind, piece) }.all?
        if attempt.error
          note_failure(attempt.error, "spooling #{attempt.pending.sum(&:size)} #{kind}")
        else
          note_success
        end
        [attempt.delivered, durable]
      end

      def push(kind, items)
        kind.to_s == 'metrics' ? @client.push_metrics(items) : @client.push_logs(items)
      end

      # Sends items, splitting on TooLarge. Once a transient or auth error is
      # hit, the remaining pieces are not attempted (the backend is struggling)
      # and are left in attempt.pending.
      def send_tree(kind, items, attempt)
        if attempt.error
          attempt.pending << items
          return
        end

        attempt.requests += 1
        push(kind, items)
        attempt.delivered += items.size
      rescue Client::TooLarge => e
        if attempt.requests >= MAX_SPLIT_REQUESTS
          attempt.pending << items
          attempt.error = e
        elsif items.size > 1
          half = (items.size + 1) / 2
          send_tree(kind, items[0, half], attempt)
          send_tree(kind, items[half..], attempt)
        else
          attempt.quarantine << [items, 'too-large', e]
        end
      rescue Client::Invalid => e
        attempt.quarantine << [items, 'invalid', e]
      rescue Client::Error => e
        attempt.pending << items
        attempt.error = e
      end

      def quarantine_all(kind, attempt)
        attempt.quarantine.each do |items, reason, error|
          @buffer.quarantine(kind, items, reason: reason, detail: error.message)
        end
      end

      # Replays spooled batches oldest first, within the per-tick budget.
      # Returns the number of items delivered.
      def drain_buffer
        return 0 if waiting?

        replayed = 0
        batches = 0
        bytes = 0
        started = @clock.call
        @buffer.each_batch do |kind, items, path, size|
          break if batches >= @config.replay_max_batches
          break if batches.positive? && bytes + size > @config.replay_max_bytes
          break if @clock.call - started >= @config.replay_max_seconds

          batches += 1
          bytes += size
          unless KINDS.include?(kind.to_s)
            @buffer.quarantine(kind, items, reason: 'unknown-kind', detail: "kind #{kind.inspect}",
                                            source: File.basename(path))
            @buffer.delete(path)
            next
          end

          attempt = Attempt.new
          send_tree(kind, items, attempt)
          quarantine_all(kind, attempt)
          replayed += attempt.delivered

          if attempt.error
            # Partly delivered after a split: keep only what is still pending.
            @buffer.replace(path, kind, attempt.pending) unless attempt.pending == [items]
            note_failure(attempt.error, 'buffer replay paused')
            break
          end

          @buffer.delete(path)
          note_success
        end
        replayed
      end

      def waiting?
        !@retry_at.nil? && @clock.call < @retry_at
      end

      def note_success
        if @auth_failing
          @auth_failing = false
          @logger.info('celerbrake-agent: Celerbrake accepts the project key again; resuming delivery')
        end
        @consecutive_failures = 0
        @retry_at = nil
      end

      def note_failure(error, action)
        @consecutive_failures += 1
        delay = error.retry_after ? [error.retry_after.to_f, MIN_BACKOFF].max : backoff_delay
        @retry_at = @clock.call + delay

        reason = error.message.sub(/:\s*\z/, '') # an empty response body leaves a trailing colon
        if error.is_a?(Client::Unauthorized)
          @auth_failures += 1
          unless @auth_failing
            @auth_failing = true
            @logger.error(
              "#{reason}: the project key was refused; #{action} until it is fixed " \
              '(this is logged once, see celerbrake_agent_auth_failures_total)'
            )
          end
          return
        end

        @logger.error("#{reason}: #{action}; next attempt in #{delay.round(1)}s")
      end

      # Exponential backoff with jitter: 1s, 2s, 4s, ... capped at 5 minutes,
      # each scaled by a random factor in [0.5, 1.0] so a fleet that lost
      # Celerbrake at the same moment does not come back in lockstep.
      def backoff_delay
        base = [MIN_BACKOFF * (2**[@consecutive_failures - 1, 16].min), MAX_BACKOFF].min
        (base * (0.5 + (@rng.rand * 0.5))).clamp(MIN_BACKOFF, MAX_BACKOFF)
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
