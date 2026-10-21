module Celerbrake
  module Agent
    # Scraped Prometheus text (Net::HTTP bodies) and tailed log lines (read in
    # binary mode) arrive as ASCII-8BIT. Handing those to JSON.generate warns on
    # json 2.x and *raises* on 3.0, so every string in a payload is coerced to
    # valid UTF-8 first; scrub replaces any genuinely-invalid bytes. Shared by
    # the client (wire payloads) and the buffer (spooled batches).
    module Utf8
      module_function

      def coerce(obj)
        case obj
        when String
          return obj if obj.encoding == ::Encoding::UTF_8 && obj.valid_encoding?

          obj.dup.force_encoding(::Encoding::UTF_8).scrub
        when Hash
          obj.each_with_object({}) { |(k, v), acc| acc[coerce(k)] = coerce(v) }
        when Array
          obj.map { |v| coerce(v) }
        else
          obj
        end
      end

      def generate(obj)
        JSON.generate(coerce(obj))
      end
    end
  end
end
