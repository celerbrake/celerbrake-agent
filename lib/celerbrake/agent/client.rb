require 'net/http'
require 'uri'
require 'json'

module Celerbrake
  module Agent
    # Pushes batches to a Celerbrake instance's ingestion endpoints, authenticated
    # with the project key (Authorization: Bearer). Plain JSON for now (Rack doesn't
    # auto-decompress request bodies; gzip would need server-side middleware).
    class Client
      class Error < StandardError; end

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
        req.body = JSON.generate(payload)

        response =
          begin
            http.request(req)
          rescue StandardError => e
            # Network/timeout errors (ECONNREFUSED, EOFError, timeouts, …) become
            # Client::Error too, so the runner buffers + retries instead of crashing.
            raise Error, "celerbrake-agent: POST #{path} failed: #{e.class}: #{e.message}"
          end

        code = response.code.to_i
        return response if code.between?(200, 299)

        raise Error, "celerbrake-agent: POST #{path} -> #{code}: #{response.body.to_s[0, 200]}"
      end
    end
  end
end
