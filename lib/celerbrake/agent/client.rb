require 'net/http'
require 'uri'
require 'json'
require 'time'

module Celerbrake
  module Agent
    # Pushes batches to a Celerbrake instance's ingestion endpoints, authenticated
    # with the project key (Authorization: Bearer). Plain JSON for now (Rack doesn't
    # auto-decompress request bodies; gzip would need server-side middleware).
    #
    # Every failure raises a subclass of Client::Error carrying the HTTP status
    # (nil for a transport failure) and the server's Retry-After in seconds (nil
    # when absent), so the runner can tell a batch that will never succeed
    # (TooLarge, Invalid) from an outage it should wait out (RateLimited,
    # ServerError, Transport) and from a key problem (Unauthorized).
    class Client
      class Error < StandardError
        attr_reader :status, :retry_after

        def initialize(message = nil, status: nil, retry_after: nil)
          super(message)
          @status = status
          @retry_after = retry_after
        end

        # Permanent errors: resending the same bytes can never succeed.
        def permanent?
          false
        end
      end

      # 413, or the server's 422 "batch-too-large" (item count over its cap).
      # Fixed by splitting the batch.
      class TooLarge < Error
        def permanent?
          true
        end
      end

      # 400 / 422: the server cannot accept this payload.
      class Invalid < Error
        def permanent?
          true
        end
      end

      # 401 / 403: the project key is wrong or was revoked. Not permanent for
      # the DATA (a corrected key will accept it), so batches are spooled.
      class Unauthorized < Error; end

      # 429: over the project's rate limit or quota; honour Retry-After.
      class RateLimited < Error; end

      # 5xx, and any other unexpected non-2xx status: retryable.
      class ServerError < Error; end

      # Network failure or timeout (no HTTP status).
      class Transport < Error; end

      # The server never asks for more than 900s (NoticeRateLimit); a larger
      # value is a bug or a hostile proxy and is clamped.
      MAX_RETRY_AFTER = 900

      def initialize(host:, project_id:, project_key:, logger:, open_timeout: 5, read_timeout: 10)
        @base         = URI.parse(host)
        @project_id   = project_id
        @project_key  = project_key
        @logger       = logger
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # @return [Integer] number of samples accepted
      def push_metrics(samples)
        return 0 if samples.nil? || samples.empty?

        post("/api/v3/projects/#{@project_id}/metrics", { samples: samples })
        samples.size
      end

      # @return [Integer] number of events accepted
      def push_logs(events)
        return 0 if events.nil? || events.empty?

        post("/api/v3/projects/#{@project_id}/logs", { events: events })
        events.size
      end

      # Seconds to wait from a Retry-After header value (delta-seconds or an
      # HTTP-date), or nil when absent or unparseable.
      def self.parse_retry_after(value, now: Time.now)
        str = value.to_s.strip
        return nil if str.empty? || str.length > 64

        secs =
          if str.match?(/\A\d+\z/)
            str.to_i
          else
            (Time.httpdate(str) - now).ceil
          end
        secs.clamp(0, MAX_RETRY_AFTER)
      rescue ArgumentError
        nil
      end

      private

      def post(path, payload)
        uri = @base.dup
        uri.path = path

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        req = Net::HTTP::Post.new(uri.request_uri)
        req['Authorization'] = "Bearer #{@project_key}"
        req['Content-Type']  = 'application/json'
        req['User-Agent']    = "celerbrake-agent/#{Celerbrake::Agent::VERSION} Ruby/#{RUBY_VERSION}"
        req.body = Utf8.generate(payload)

        response =
          begin
            http.request(req)
          rescue StandardError => e
            # Network/timeout errors (ECONNREFUSED, EOFError, timeouts, ...) become
            # Client::Transport, so the runner buffers + retries instead of crashing.
            raise Transport, "celerbrake-agent: POST #{path} failed: #{e.class}: #{e.message}"
          end

        code = response.code.to_i
        return response if code.between?(200, 299)

        body = response.body.to_s
        raise error_class(code, body).new(
          "celerbrake-agent: POST #{path} -> #{code}: #{body[0, 200]}",
          status: code,
          retry_after: self.class.parse_retry_after(response['Retry-After'])
        )
      end

      def error_class(code, body)
        case code
        when 413 then TooLarge
        when 422 then batch_too_large?(body) ? TooLarge : Invalid
        when 400 then Invalid
        when 401, 403 then Unauthorized
        when 429 then RateLimited
        else ServerError
        end
      end

      # Celerbrake answers an over-count batch with 422 {"reason":"batch-too-large"}
      # (the byte cap is a 413). Both are fixed by splitting.
      def batch_too_large?(body)
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) && parsed['reason'] == 'batch-too-large'
      rescue JSON::ParserError
        false
      end
    end
  end
end
