require 'json'

module Celerbrake
  module Agent
    # Tails a log file, returning lines appended since the last read as log-event
    # hashes. On first read it seeks to the end (a daemon ships only new lines,
    # not the historical log); a truncation/rotation resets to the start of the
    # new file. A partial (newline-less) trailing line is left until it completes
    # so a record is never split.
    #
    # Lines may be pure JSON (one structured event per line) OR standard Ruby
    # Logger output — "I, [2026-05-24T21:30:25.5 #4123]  INFO -- : <message>".
    # For the latter we lift the level + timestamp from the prefix, then treat
    # what follows as JSON (lograge requests, db.slow_query events, AppError) or
    # a plain message. Anything we can't recognize is forwarded as a raw event
    # rather than dropped.
    class LogTailer
      MAX_LINES_PER_READ = 2_000

      # Ruby's Logger::Formatter: "%s, [%s #%d] %5s -- %s: %s". Captures the
      # timestamp, the severity label, and the message that follows.
      RAILS_PREFIX = /\A[DIWEFA], \[([^\]]+?) \#\d+\]\s+(DEBUG|INFO|WARN|ERROR|FATAL|ANY)\s+--\s+[^:]*:\s?(.*)\z/m
      SEVERITY = { 'DEBUG' => 'debug', 'INFO' => 'info', 'WARN' => 'warn',
                   'ERROR' => 'error', 'FATAL' => 'fatal', 'ANY' => 'unknown' }.freeze

      def initialize(path:, logger:)
        @path = path
        @logger = logger
        @pos = nil
      end

      def read_new
        return [] unless File.exist?(@path)

        size = File.size(@path)
        if @pos.nil?
          @pos = size # first run: start at end
          return []
        end
        @pos = 0 if size < @pos # truncated / rotated
        return [] if size <= @pos

        events = []
        File.open(@path, 'rb') do |f|
          f.seek(@pos)
          f.each_line do |line|
            break unless line.end_with?("\n") # partial line — re-read next tick

            @pos = f.pos
            ev = parse_line(line.chomp)
            events << ev if ev
            break if events.size >= MAX_LINES_PER_READ
          end
        end
        events
      rescue StandardError => e
        @logger.error("celerbrake-agent: tail #{@path} failed: #{e.class}: #{e.message}")
        []
      end

      def to_s
        @path
      end

      private

      def parse_line(line)
        return nil if line.strip.empty?

        ts_hint = level_hint = nil
        payload = line
        if (m = RAILS_PREFIX.match(line))
          ts_hint    = m[1]
          level_hint = SEVERITY[m[2]]
          payload    = m[3]
        end

        obj = parse_json(payload)
        if obj.is_a?(Hash)
          {
            ts:         obj['time'] || obj['timestamp'] || ts_hint,
            level:      obj['level'] || derive_level(obj) || level_hint || 'info',
            message:    obj['message'] || synth_message(obj),
            request_id: obj['request_id'],
            source:     (obj.key?('method') && obj.key?('path')) ? 'request' : 'app',
            fields:     obj
          }
        elsif level_hint
          # A standard Rails/Ruby Logger line that isn't JSON — keep the message
          # and use the level lifted from the prefix.
          { ts: ts_hint, source: 'app', level: level_hint, message: payload, fields: {} }
        else
          raw_event(payload)
        end
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

      def synth_message(obj)
        return '' unless obj['method'] && obj['path']

        "#{obj['method']} #{obj['path']}#{obj['status'] ? " -> #{obj['status']}" : ''}"
      end
    end
  end
end
