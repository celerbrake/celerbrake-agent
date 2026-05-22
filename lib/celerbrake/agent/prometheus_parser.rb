module Celerbrake
  module Agent
    # Parses Prometheus text exposition (what /api/metrics emits) into samples:
    #   [{ name:, type:, labels: { String => String }, value: Float }, ... ]
    #
    # Each histogram series (_bucket/_sum/_count) is emitted as its own sample,
    # carrying the histogram type so the server can roll it up later. Label
    # parsing handles escaped quotes and commas inside values.
    module PrometheusParser
      module_function

      METRIC_LINE = /
        \A
        (?<name>[a-zA-Z_:][a-zA-Z0-9_:]*)
        (?:\{(?<labels>.*)\})?
        \s+
        (?<value>[^\s]+)
        (?:\s+[0-9.eE+-]+)?   # optional trailing timestamp — ignored
        \z
      /x

      LABEL_PAIR = /([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"/

      def parse(text)
        type_map = {}
        samples = []

        text.to_s.each_line do |raw|
          line = raw.strip
          next if line.empty?

          if line.start_with?('#')
            if (m = line.match(/\A#\s*TYPE\s+(\S+)\s+(\S+)/))
              type_map[m[1]] = m[2]
            end
            next
          end

          m = line.match(METRIC_LINE)
          next unless m

          value = parse_value(m[:value])
          next if value.nil?

          samples << {
            name:   m[:name],
            type:   type_for(m[:name], type_map),
            labels: parse_labels(m[:labels]),
            value:  value
          }
        end

        samples
      end

      def parse_value(str)
        Float(str)
      rescue ArgumentError, TypeError
        nil # skip non-finite/non-numeric values (e.g. NaN, +Inf gauges)
      end

      def parse_labels(str)
        return {} if str.nil? || str.empty?

        str.scan(LABEL_PAIR).each_with_object({}) do |(key, val), out|
          out[key] = val.gsub('\\"', '"').gsub('\\n', "\n").gsub('\\\\', '\\')
        end
      end

      # Histogram/counter series share a base name's declared TYPE; fall back to
      # stripping the _bucket/_sum/_count/_total suffix to find it.
      def type_for(name, type_map)
        return type_map[name] if type_map.key?(name)

        base = name.sub(/_(bucket|sum|count|total)\z/, '')
        type_map[base] || 'untyped'
      end
    end
  end
end
