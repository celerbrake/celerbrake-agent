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
    # For the latter we lift the level + timestamp from the prefix. Rails also
    # prepends tagged-logging brackets ahead of the payload — "[request_id]" from
    # config.log_tags on requests, and "[ActiveJob] [JobClass] [job_id]" around
    # every job's perform (ActiveJob::Logging) — so the JSON does not start at the
    # front of the line. We peel those "[..]" tags off, then treat what follows as
    # JSON (lograge requests, job logs, metrics, db.slow_query, AppError) or a
    # plain message, lifting a UUID-shaped tag as the correlation request_id and
    # synthesizing a readable message when the JSON has no `message` key. Anything
    # we can't recognize is forwarded as a raw event rather than dropped.
    class LogTailer
      MAX_LINES_PER_READ = 2_000

      # Ruby's Logger::Formatter: "%s, [%s #%d] %5s -- %s: %s". Captures the
      # timestamp, the severity label, and the message that follows.
      RAILS_PREFIX = /\A[DIWEFA], \[([^\]]+?) \#\d+\]\s+(DEBUG|INFO|WARN|ERROR|FATAL|ANY)\s+--\s+[^:]*:\s?(.*)\z/m
      SEVERITY = { 'DEBUG' => 'debug', 'INFO' => 'info', 'WARN' => 'warn',
                   'ERROR' => 'error', 'FATAL' => 'fatal', 'ANY' => 'unknown' }.freeze

      # A leading tagged-logging bracket, e.g. "[ActiveJob] " or "[<uuid>] ".
      TAG            = /\A\[([^\]]*)\]\s*/
      UUID           = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      ACTIVE_JOB_TAG = 'ActiveJob'

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
