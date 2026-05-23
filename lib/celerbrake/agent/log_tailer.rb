require 'json'

module Celerbrake
  module Agent
    # Tails a JSON log file, returning lines appended since the last read as
    # log-event hashes. On first read it seeks to the end (a daemon ships only
    # new lines, not the historical log); a truncation/rotation resets to the
    # start of the new file. Non-JSON lines are forwarded as raw events rather
    # than dropped, and a partial (newline-less) trailing line is left until it
    # completes so a JSON object is never split.
    class LogTailer
      MAX_LINES_PER_READ = 2_000

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

        obj =
          begin
            JSON.parse(line)
          rescue JSON::ParserError
            return raw_event(line)
          end
        return raw_event(line) unless obj.is_a?(Hash)

        {
          ts:         obj['time'] || obj['timestamp'],
          level:      obj['level'] || derive_level(obj),
          message:    obj['message'] || synth_message(obj),
          request_id: obj['request_id'],
          source:     (obj.key?('method') && obj.key?('path')) ? 'request' : 'app',
          fields:     obj
        }
      end

      def raw_event(line)
        { source: 'raw', level: 'unknown', message: line, fields: {} }
      end

      def derive_level(obj)
        return 'error' if obj['exception_class']

        status = obj['status']
        return 'info' unless status.is_a?(Integer)

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
