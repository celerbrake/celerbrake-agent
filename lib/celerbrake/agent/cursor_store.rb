require 'json'
require 'fileutils'
require 'securerandom'

module Celerbrake
  module Agent
    # Persists each tailed file's read position (state.dir/cursor.json) so a
    # restarted agent resumes where the last one stopped instead of skipping
    # what was written while it was down. Written atomically (temp file in the
    # same directory, fsync, rename). Shape:
    #
    #   { "version": 1,
    #     "files": { "/rails/log/production.log":
    #                { "dev": 2049, "ino": 131, "pos": 5120, "size": 6000,
    #                  "sig": "<hex of the 32 bytes before pos>",
    #                  "updated_at": "2026-10-20T12:00:00Z" } } }
    class CursorStore
      FILE = 'cursor.json'.freeze
      VERSION = 1

      def initialize(dir:, logger:)
        @dir = dir
        @path = File.join(dir, FILE)
        @logger = logger
        @files = load
      end

      attr_reader :path

      def [](key)
        @files[key]
      end

      # Records a position and writes the file. Returns true on success.
      def store(key, entry)
        @files[key] = entry
        save
      end

      private

      def load
        return {} unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        files = data.is_a?(Hash) ? data['files'] : nil
        files.is_a?(Hash) ? files : {}
      rescue StandardError => e
        @logger.warn(
          "celerbrake-agent: cursor file #{@path} is unreadable (#{e.class}: #{e.message}); " \
          'treating every log as a first run'
        )
        {}
      end

      def save
        FileUtils.mkdir_p(@dir)
        tmp = "#{@path}.#{SecureRandom.hex(4)}.tmp"
        File.open(tmp, 'wb') do |f|
          f.write(JSON.generate(version: VERSION, files: @files))
          f.flush
          f.fsync
        end
        File.rename(tmp, @path)
        true
      rescue StandardError => e
        @logger.error("celerbrake-agent: cursor write #{@path} failed: #{e.class}: #{e.message}")
        false
      ensure
        File.delete(tmp) if tmp && File.exist?(tmp)
      end
    end
  end
end
