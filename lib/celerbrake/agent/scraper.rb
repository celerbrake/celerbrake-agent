require 'net/http'
require 'uri'

module Celerbrake
  module Agent
    # Scrapes a single Prometheus /api/metrics endpoint. Returns the exposition
    # text, or nil on any failure (logged) — a missed scrape is not fatal; the
    # next tick tries again.
    class Scraper
      def initialize(url:, logger:, token: nil, open_timeout: 5, read_timeout: 10)
        @uri          = URI.parse(url)
        @token        = token
        @logger       = logger
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def scrape
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = (@uri.scheme == 'https')
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        req = Net::HTTP::Get.new(@uri.request_uri)
        req['Authorization'] = "Bearer #{@token}" if @token && !@token.to_s.empty?

        response = http.request(req)
        code = response.code.to_i
        return response.body if code.between?(200, 299)

        @logger.error("celerbrake-agent: scrape #{@uri} -> #{code}")
        nil
      rescue StandardError => e
        @logger.error("celerbrake-agent: scrape #{@uri} failed: #{e.class}: #{e.message}")
        nil
      end

      def to_s
        @uri.to_s
      end
    end
  end
end
