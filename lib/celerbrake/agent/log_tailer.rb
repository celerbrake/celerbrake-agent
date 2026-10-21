require 'json'
require 'time'

module Celerbrake
  module Agent
    # Tails a log file, returning lines appended since the last read as log-event
    # hashes. A partial (newline-less) trailing line is left until it completes
    # so a record is never split.
    #
    # Position and durability. The read position survives restarts through a
    # CursorStore (state.dir/cursor.json) keyed by the file's device + inode:
    #   * no saved cursor (first installation): start at the END of the file,
    #     the daemon ships new lines, not the historical log. A file that did
    #     not exist yet when the agent started is shipped from byte 0 when it
    #     appears;
    #   * saved cursor, same file: resume at the saved byte. When the file is now
    #     shorter, or the bytes just before the saved offset differ (truncated
    #     and rewritten), restart at 0;
    #   * saved cursor, different file (rotated while the agent was down): if the
    #     previous file is still next to it under a rotated name, finish it from
    #     the saved byte first; then read the new file from byte 0.
    # While running, every read stats the path: an inode change means the file
    # was rotated, so the old handle is read to EOF before the new file is
    # opened at 0; in-place truncation (copytruncate) is caught by size and by
    # the signature of the bytes before the offset.
    #
    # read_new only advances an in-memory read position. The runner calls
    # commit! once the events were delivered or spooled (that persists the
    # cursor) or rewind! when they could not be made durable (the next read
    # returns the same lines). Each event carries an event_id
    # ("<dev>:<inode>:<byte offset>") so a replayed duplicate is identifiable.
    #
    # Lines may be pure JSON (one structured event per line) OR standard Ruby
    # Logger output: "I, [2026-05-24T21:30:25.5 #4123]  INFO -- : <message>".
    # For the latter we lift the level + timestamp from the prefix. Rails also
    # prepends tagged-logging brackets ahead of the payload: "[request_id]" from
    # config.log_tags on requests, and "[ActiveJob] [JobClass] [job_id]" around
    # every job's perform (ActiveJob::Logging), so the JSON does not start at the
    # front of the line. We peel those "[..]" tags off, then treat what follows as
    # JSON (lograge requests, job logs, metrics, db.slow_query, AppError) or a
    # plain message, lifting a UUID-shaped tag as the correlation request_id and
    # synthesizing a readable message when the JSON has no `message` key. Anything
    # we can't recognize is forwarded as a raw event rather than dropped.
    class LogTailer
      MAX_LINES_PER_READ = 2_000
      # Bytes before the offset remembered as a signature of "the same content".
      SIG_BYTES = 32
      # Rotated siblings examined when looking for the previous file on start.
      MAX_ROTATED_CANDIDATES = 50

      # Ruby's Logger::Formatter: "%s, [%s #%d] %5s -- %s: %s". Captures the
      # timestamp, the severity label, and the message that follows.
      RAILS_PREFIX = /\A[DIWEFA], \[([^\]]+?) \#\d+\]\s+(DEBUG|INFO|WARN|ERROR|FATAL|ANY)\s+--\s+[^:]*:\s?(.*)\z/m
      SEVERITY = { 'DEBUG' => 'debug', 'INFO' => 'info', 'WARN' => 'warn',
                   'ERROR' => 'error', 'FATAL' => 'fatal', 'ANY' => 'unknown' }.freeze

      # A leading tagged-logging bracket, e.g. "[ActiveJob] " or "[<uuid>] ".
      TAG            = /\A\[([^\]]*)\]\s*/
      UUID           = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      ACTIVE_JOB_TAG = 'ActiveJob'

      Position = Struct.new(:io, :dev, :ino, :pos, :sig, keyword_init: true)

      def initialize(path:, logger:, cursor_store: nil)
        @path = path
        @key = File.expand_path(path)
        @logger = logger
        @store = cursor_store
        @read = nil        # where the next read starts
        @committed = nil   # the last position the runner made durable
        @missing_at_start = nil
        @last_saved = nil
      end

      def read_new
        return [] unless @read || open_initial

        events = []
        2.times do # the current file, then its replacement after a rotation
          verify_position
          read_lines(events)
          break if events.size >= MAX_LINES_PER_READ
          break unless rotated?

          flush_partial(events)
          break unless switch_to_current_file
        end
        events
      rescue StandardError => e
        @logger.error("celerbrake-agent: tail #{@path} failed: #{e.class}: #{e.message}")
        rewind!
        []
      end

      # The events returned so far are durable (delivered or spooled): persist
      # the position. Returns false when the cursor file could not be written.
      def commit!
        return true unless @read

        close_io(@committed.io) if @committed && !@committed.io.equal?(@read.io)
        @committed = @read.dup
        persist
      end

      # The events returned since the last commit! were not made durable: the
      # next read_new returns them again.
      def rewind!
        return unless @committed

        close_io(@read.io) if @read && !@read.io.equal?(@committed.io)
        @read = @committed.dup
      end

      # Bytes written to the log that the tailer has not read yet.
      def lag_bytes
        return 0 unless @read

        lag = [@read.io.size - @read.pos, 0].max
        lag += stat_path&.size.to_i if rotated?
        lag
      rescue StandardError
        0
      end

      def close
        close_io(@read&.io)
        close_io(@committed&.io)
        @read = @committed = nil
      end

      def to_s
        @path
      end

      private

      def stat_path
        File.stat(@path)
      rescue SystemCallError
        nil
      end

      def close_io(io)
        io.close if io && !io.closed?
      rescue IOError
        nil
      end

      def open_initial
        unless stat_path
          @missing_at_start = true if @missing_at_start.nil?
          return false
        end

        io = File.open(@path, 'rb')
        @read = initial_position(io, io.stat, @store && @store[@key])
        @missing_at_start = false
        @committed = @read.dup
        true
      end

      def initial_position(io, st, saved)
        if saved.nil?
          if @missing_at_start
            @logger.info("celerbrake-agent: #{@path} appeared after start: shipping it from the beginning")
            return position(io, st, 0)
          end
          @logger.info("celerbrake-agent: no saved cursor for #{@path}: starting at the end of the file (first run)")
          return position(io, st, st.size)
        end

        pos = saved['pos'].to_i
        return checked_position(io, st, pos, saved['sig'], @path) if same_file?(io, st, saved)

        if (prev = find_previous(saved))
          close_io(io)
          prev_io, prev_path = prev
          @logger.info(
            "celerbrake-agent: #{@path} was rotated while the agent was down: finishing #{prev_path} " \
            "from byte #{pos}, then the new file from the start"
          )
          return checked_position(prev_io, prev_io.stat, pos, saved['sig'], prev_path)
        end

        @logger.info("celerbrake-agent: #{@path} was replaced while the agent was down: shipping the new file from the start")
        position(io, st, 0)
      end

      def checked_position(io, st, pos, sig, label)
        if st.size < pos
          @logger.warn("celerbrake-agent: #{label} is shorter than the saved cursor (truncated): reading from the start")
          return position(io, st, 0)
        end
        unless sig_matches?(io, pos, sig)
          @logger.warn("celerbrake-agent: #{label} changed before the saved cursor (rewritten): reading from the start")
          return position(io, st, 0)
        end
        @logger.info("celerbrake-agent: resuming #{label} at byte #{pos}")
        position(io, st, pos)
      end

      def position(io, st, pos)
        Position.new(io: io, dev: st.dev, ino: st.ino, pos: pos, sig: compute_sig(io, pos))
      end

      # Same inode, and the same device (or, when the device number moved, as a
      # remounted volume can do, the same bytes before the offset).
      def same_file?(io, st, saved)
        return false unless st.ino == saved['ino'].to_i
        return true if st.dev == saved['dev'].to_i

        sig = saved['sig'].to_s
        !sig.empty? && sig_matches?(io, saved['pos'].to_i, sig)
      end

      # The previous file under a rotated name next to the log
      # (production.log.1, production.log-20261020, ...), found by inode.
      def find_previous(saved)
        dir = File.dirname(@path)
        base = File.basename(@path)
        names = Dir.children(dir).select { |n| n.start_with?(base) && n != base }.sort.first(MAX_ROTATED_CANDIDATES)
        names.each do |name|
          candidate = File.join(dir, name)
          st = File.stat(candidate)
          next unless st.file? && st.ino == saved['ino'].to_i && st.dev == saved['dev'].to_i

          return [File.open(candidate, 'rb'), candidate]
        end
        nil
      rescue SystemCallError
        nil
      end

      def compute_sig(io, pos)
        len = [pos, SIG_BYTES].min
        return '' if len <= 0

        io.pread(len, pos - len).unpack1('H*')
      rescue EOFError, SystemCallError
        ''
      end

      def sig_matches?(io, pos, sig)
        return true if sig.nil? || sig.to_s.empty?
        return false if io.size < pos

        compute_sig(io, pos) == sig
      end

      # In-place truncation (copytruncate) of the file being read.
      def verify_position
        size = @read.io.size
        if size < @read.pos
          @logger.info("celerbrake-agent: #{@path} was truncated: reading from the start")
          reset_read_position
        elsif !sig_matches?(@read.io, @read.pos, @read.sig)
          @logger.info("celerbrake-agent: #{@path} was truncated and rewritten: reading from the start")
          reset_read_position
        end
      end

      def reset_read_position
        @read.pos = 0
        @read.sig = ''
      end

      def read_lines(events)
        io = @read.io
        return if io.size <= @read.pos

        io.seek(@read.pos)
        io.each_line do |line|
          break unless line.end_with?("\n") # partial line: re-read next tick

          start = @read.pos
          @read.pos += line.bytesize
          add_event(events, line.chomp, start)
          break if events.size >= MAX_LINES_PER_READ
        end
        @read.sig = compute_sig(io, @read.pos)
      end

      # The path now names a different file than the handle being read.
      def rotated?
        st = stat_path
        return false unless st

        st.ino != @read.ino || st.dev != @read.dev
      end

      # The rotated-away file is at EOF: a trailing line without a newline will
      # never be completed, so ship it as it is.
      def flush_partial(events)
        io = @read.io
        size = io.size
        return if size <= @read.pos

        start = @read.pos
        tail = io.pread(size - start, start)
        @read.pos = size
        @read.sig = compute_sig(io, size)
        add_event(events, tail.chomp, start)
      end

      def switch_to_current_file
        io = File.open(@path, 'rb')
        st = io.stat
        old = @read
        @read = Position.new(io: io, dev: st.dev, ino: st.ino, pos: 0, sig: '')
        close_io(old.io) unless @committed && old.io.equal?(@committed.io)
        @logger.info("celerbrake-agent: #{@path} was rotated: finished the previous file, reading the new one from the start")
        true
      rescue SystemCallError
        false # the path vanished again between stat and open; retry next tick
      end

      def add_event(events, line, offset)
        ev = parse_line(line)
        return unless ev

        ev[:event_id] = "#{@read.dev}:#{@read.ino}:#{offset}"
        events << ev
      end

      def persist
        return true unless @store

        c = @committed
        entry = { 'dev' => c.dev, 'ino' => c.ino, 'pos' => c.pos, 'size' => c.io.size, 'sig' => c.sig.to_s }
        return true if entry == @last_saved

        ok = @store.store(@key, entry.merge('updated_at' => Time.now.utc.iso8601))
        @last_saved = entry if ok
        ok
      end

      def parse_line(line)
        return nil if line.strip.empty?

        ts_hint = level_hint = nil
        payload = line
        if (m = RAILS_PREFIX.match(line))
          ts_hint    = m[1]
          level_hint = SEVERITY[m[2]]
          payload    = m[3]
        end

        tags, rest = strip_tags(payload)
        obj = parse_json(rest)
        if obj.is_a?(Hash)
          {
            ts:         obj['time'] || obj['timestamp'] || ts_hint,
            level:      obj['level'] || derive_level(obj) || level_hint || 'info',
            message:    obj['message'] || synth_message(obj),
            request_id: obj['request_id'] || correlation_tag(tags),
            source:     source_for(obj, tags),
            fields:     obj
          }
        elsif level_hint
          # A standard Rails/Ruby Logger line that isn't JSON — keep the original
          # message (tags and all) and use the level lifted from the prefix.
          { ts: ts_hint, source: 'app', level: level_hint, message: payload, fields: {} }
        else
          raw_event(payload)
        end
      end

      # Peels leading "[..]" tagged-logging brackets off the payload, returning
      # [tags, remainder]. Only consequential when the remainder is JSON; for a
      # plain-text line the caller keeps the original (un-peeled) payload, so a
      # message like "[ActiveJob] Performed X" is preserved verbatim.
      def strip_tags(payload)
        tags = []
        rest = payload
        while (m = TAG.match(rest))
          tags << m[1]
          rest = rest[m.end(0)..]
        end
        [tags, rest]
      end

      # The correlation id Rails put in a tag: request_id on a request, job_id on
      # a job. Both are UUIDs; take the last (job_id trails the [ActiveJob][Class]
      # tags). Lets the dashboard group every line from one request/job execution.
      def correlation_tag(tags)
        tags.reverse_each.find { |t| t.match?(UUID) }
      end

      def source_for(obj, tags)
        return 'job'     if tags.include?(ACTIVE_JOB_TAG)
        return 'request' if obj.key?('method') && obj.key?('path')

        'app'
      end

      def parse_json(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def raw_event(line)
        { source: 'raw', level: 'unknown', message: line, fields: {} }
      end

      # @return [String, nil] level inferred from the payload, or nil to let the
      #   caller fall back to the log-prefix level.
      def derive_level(obj)
        return 'error' if obj['exception_class']

        status = obj['status']
        return nil unless status.is_a?(Integer)

        if status >= 500 then 'error'
        elsif status >= 400 then 'warn'
        else 'info'
        end
      end

      # A short, human message for a structured line that carries no `message`
      # key — so the dashboard's Message column is never blank or a raw JSON dump.
      def synth_message(obj)
        if (event = obj['event'])
          synth_event(event, obj)
        elsif obj['method'] && obj['path'] # lograge request (no `event` key)
          "#{obj['method']} #{obj['path']}#{obj['status'] ? " -> #{obj['status']}" : ''}"
        elsif (metric = obj['metric'])
          "metric #{metric}#{obj.key?('value') ? "=#{obj['value']}" : ''}"
        else
          ''
        end
      end

      def synth_event(event, obj)
        case event
        when %r{\Ajob\.} # job.enqueue / job.perform / job.discard / ...
          msg  = [event, obj['job']].compact.join(' ')
          msg += " (#{obj['duration_ms']}ms)" if obj['duration_ms']
          msg += " #{obj['status']}" if obj['status'] && obj['status'] != 'ok'
          msg
        when 'db.slow_query'
          "#{event} #{obj['duration_ms']}ms #{obj['sql_shape'] || obj['fingerprint']}".strip
        else # generic event, e.g. "coinbase_api.response GET /v3/orders -> 200"
          detail  = [obj['method'], obj['path']].compact.join(' ')
          detail += " -> #{obj['status']}" if obj['status']
          detail.empty? ? event : "#{event} #{detail}"
        end
      end
    end
  end
end
