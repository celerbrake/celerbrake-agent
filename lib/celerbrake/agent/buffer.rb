require 'json'
require 'fileutils'
require 'securerandom'

module Celerbrake
  module Agent
    # A tiny disk-backed queue for batches that failed to push, so a Celerbrake
    # outage doesn't lose data — the runner replays buffered batches on later
    # ticks. Bounded by max_bytes; when full, the oldest batches are dropped
    # (counted and logged). One file per batch; filenames sort oldest-first.
    class Buffer
      def initialize(dir:, logger:, max_bytes: 100_000_000)
        @dir = dir
        @logger = logger
        @max_bytes = max_bytes
        @dropped = 0
        FileUtils.mkdir_p(@dir)
      end

      attr_reader :dropped

      def enqueue(kind, items)
        prune!
        name = "#{format('%020d', Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond))}-#{SecureRandom.hex(4)}.json"
        File.write(File.join(@dir, name), JSON.generate(kind: kind.to_s, items: items))
      rescue StandardError => e
        @logger.error("celerbrake-agent: buffer write failed: #{e.class}: #{e.message}")
      end

      # Yields [kind, items, path] for each buffered batch, oldest first.
      def each_batch
        files.each do |path|
          data =
            begin
              JSON.parse(File.read(path))
            rescue StandardError
              File.delete(path) # corrupt entry — drop it
              next
            end
          yield data['kind'], data['items'], path
        end
      end

      def delete(path)
        File.delete(path) if File.exist?(path)
      end

      def size_bytes
        files.sum { |f| File.size(f) }
      end

      private

      def files
        Dir.glob(File.join(@dir, '*.json')).sort
      end

      # Drop oldest batches until under the cap. Called before each enqueue.
      def prune!
        list = files
        total = list.sum { |f| File.size(f) }
        while total > @max_bytes && list.any?
          victim = list.shift
          total -= File.size(victim)
          delete(victim)
          @dropped += 1
          @logger.warn("celerbrake-agent: buffer over #{@max_bytes}B — dropped oldest batch (#{@dropped} dropped total)")
        end
      end
    end
  end
end
