require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module Celerbrake
  module Agent
    # A small disk-backed queue for batches that could not be delivered, so a
    # Celerbrake outage does not lose data: the runner replays spooled batches
    # on later ticks. One file per batch; filenames sort oldest first.
    #
    # Disk policy:
    #   * every file is written to a temp name in the same directory, fsynced
    #     and renamed into place, so a crash never leaves a truncated batch
    #     (leftover temp files are swept on start);
    #   * the incoming batch is accounted for BEFORE it is written: the oldest
    #     batches are dropped (counted in #dropped) until existing + incoming
    #     fits in max_bytes;
    #   * a batch over max_batch_bytes is split at enqueue, and a single item
    #     over it is quarantined rather than spooled;
    #   * batches that can never be delivered go to quarantine/, a separate
    #     directory with its own cap, each with its reason (counted in
    #     #quarantined). Entries too big for that cap keep only the reason and
    #     the item count.
    class Buffer
      DEFAULT_MAX_BYTES = 100_000_000
      DEFAULT_MAX_BATCH_BYTES = 4 * 1024 * 1024
      DEFAULT_QUARANTINE_MAX_BYTES = 10_000_000
      QUARANTINE_DIR = 'quarantine'.freeze
      # Spooled batch names: <20-digit ns>-<hex>[-<NNN> per split].json. Anything
      # else in the directory (a cursor file, an operator's notes) is ignored.
      BATCH_NAME = /\A\d{20}-[0-9a-f]+(?:-\d{3})*\.json\z/.freeze

      def initialize(dir:, logger:, max_bytes: DEFAULT_MAX_BYTES,
                     max_batch_bytes: DEFAULT_MAX_BATCH_BYTES,
                     quarantine_max_bytes: DEFAULT_QUARANTINE_MAX_BYTES)
        @dir = dir
        @qdir = File.join(dir, QUARANTINE_DIR)
        @logger = logger
        @max_bytes = max_bytes.to_i
        @max_batch_bytes = [max_batch_bytes.to_i, @max_bytes].min
        @quarantine_max_bytes = quarantine_max_bytes.to_i
        @dropped = 0
        @quarantined = 0
        @seq = 0
        FileUtils.mkdir_p(@dir)
        FileUtils.mkdir_p(@qdir)
        sweep_temp_files
      end

      attr_reader :dropped, :quarantined, :max_batch_bytes

      # Splits items into slices whose spooled JSON fits max_batch_bytes.
      # Returns [slices, oversized_items]: an item that alone exceeds the limit
      # cannot be sent or spooled and is returned separately.
      def slice(kind, items)
        return [[], []] if items.nil? || items.empty?

        # The spooled envelope around the items: {"kind":"logs","items":[...]}.
        limit = @max_batch_bytes - (Utf8.generate(kind: kind.to_s, items: []).bytesize - 2)
        return [[items], []] if Utf8.generate(items).bytesize <= limit

        slices = []
        oversized = []
        current = []
        current_bytes = 2 # the brackets
        items.each do |item|
          bytes = Utf8.generate(item).bytesize + 1 # plus the comma
          if bytes > limit
            oversized << item
            next
          end
          if current_bytes + bytes > limit && current.any?
            slices << current
            current = []
            current_bytes = 2
          end
          current << item
          current_bytes += bytes
        end
        slices << current if current.any?
        [slices, oversized]
      end

      # Spools a batch (split as needed). Returns true when everything was
      # either written or deliberately dropped/quarantined by policy, false when
      # a write failed (disk error), so the caller can keep the data elsewhere.
      def enqueue(kind, items)
        slices, oversized = slice(kind, items)
        oversized.each do |item|
          quarantine(kind, [item], reason: 'item-too-large',
                                   detail: "one item is larger than max_batch_bytes (#{@max_batch_bytes}B)")
        end
        slices.map { |s| write_batch(next_name, kind, s) }.all?
      end

      # Replaces a spooled batch with the pieces of it that are still pending
      # (after a partial delivery of a split batch). The pieces keep the
      # original's place in the replay order.
      def replace(path, kind, pieces)
        base = File.basename(path, '.json')
        ok = pieces.each_with_index.map do |piece, i|
          write_batch(format('%s-%03d.json', base, i + 1), kind, piece, exclude: path)
        end.all?
        delete(path) if ok
        ok
      end

      # Moves a batch that can never be delivered out of the replay path,
      # keeping the reason (and the items when they fit the quarantine cap).
      def quarantine(kind, items, reason:, detail: nil, source: nil)
        @quarantined += 1
        entry = {
          kind: kind.to_s, reason: reason.to_s, detail: detail.to_s[0, 500],
          quarantined_at: Time.now.utc.iso8601, item_count: Array(items).size,
          source: source, items: items
        }
        json = Utf8.generate(entry)
        if json.bytesize > @quarantine_max_bytes
          entry[:items] = []
          entry[:items_omitted_bytes] = json.bytesize
          json = Utf8.generate(entry)
        end
        @logger.error(
          "celerbrake-agent: quarantined #{Array(items).size} #{kind} (#{reason}): #{detail.to_s[0, 200]} " \
          "(#{@quarantined} quarantined total)"
        )
        return false if json.bytesize > @quarantine_max_bytes

        prune_quarantine(json.bytesize)
        write_atomic(File.join(@qdir, next_name), json)
      rescue StandardError => e
        @logger.error("celerbrake-agent: quarantine write failed: #{e.class}: #{e.message}")
        false
      end

      # Yields [kind, items, path, bytes] for each spooled batch, oldest first.
      # An unreadable entry is moved to quarantine (reason "corrupt").
      def each_batch
        files.each do |path|
          next unless File.exist?(path)

          bytes = File.size(path)
          data =
            begin
              JSON.parse(File.read(path))
            rescue StandardError => e
              quarantine_corrupt(path, e)
              next
            end
          unless data.is_a?(Hash) && data['items'].is_a?(Array)
            quarantine_corrupt(path, 'not a batch object')
            next
          end
          yield data['kind'], data['items'], path, bytes
        end
      end

      def delete(path)
        File.delete(path) if File.exist?(path)
      end

      def size_bytes
        files.sum { |f| safe_size(f) }
      end

      def quarantine_bytes
        quarantine_files.sum { |f| safe_size(f) }
      end

      private

      def files
        Dir.children(@dir).grep(BATCH_NAME).sort.map { |n| File.join(@dir, n) }
      rescue SystemCallError
        []
      end

      def quarantine_files
        Dir.children(@qdir).grep(BATCH_NAME).sort.map { |n| File.join(@qdir, n) }
      rescue SystemCallError
        []
      end

      def safe_size(path)
        File.size(path)
      rescue SystemCallError
        0
      end

      def next_name
        @seq = (@seq + 1) % 1_000_000
        ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        format('%020d-%06x%s.json', ns, @seq, SecureRandom.hex(3))
      end

      def write_batch(name, kind, items, exclude: nil)
        json = Utf8.generate(kind: kind.to_s, items: items)
        unless make_room(json.bytesize, exclude: exclude)
          @dropped += 1
          @logger.error(
            "celerbrake-agent: buffer cannot hold a #{json.bytesize}B batch (max_bytes #{@max_bytes}): " \
            "dropped #{items.size} #{kind} (#{@dropped} dropped total)"
          )
          return true # handled by policy: retrying cannot make it fit
        end
        write_atomic(File.join(@dir, name), json)
      rescue StandardError => e
        @logger.error("celerbrake-agent: buffer write failed: #{e.class}: #{e.message}")
        false
      end

      # Drops the oldest batches until existing + incoming <= max_bytes.
      # Returns false when the incoming batch cannot fit even in an empty buffer.
      def make_room(incoming, exclude: nil)
        return false if incoming > @max_bytes

        list = files
        total = list.sum { |f| safe_size(f) }
        list.delete(exclude)
        while total + incoming > @max_bytes && list.any?
          victim = list.shift
          total -= safe_size(victim)
          delete(victim)
          @dropped += 1
          @logger.warn(
            "celerbrake-agent: buffer over #{@max_bytes}B: dropped the oldest batch (#{@dropped} dropped total)"
          )
        end
        total + incoming <= @max_bytes
      end

      def prune_quarantine(incoming)
        list = quarantine_files
        total = list.sum { |f| safe_size(f) }
        while total + incoming > @quarantine_max_bytes && list.any?
          victim = list.shift
          total -= safe_size(victim)
          File.delete(victim) if File.exist?(victim)
        end
      end

      def write_atomic(path, data)
        tmp = "#{path}.#{SecureRandom.hex(4)}.tmp"
        File.open(tmp, 'wb') do |f|
          f.write(data)
          f.flush
          f.fsync
        end
        File.rename(tmp, path)
        true
      ensure
        File.delete(tmp) if tmp && File.exist?(tmp)
      end

      def quarantine_corrupt(path, error)
        head = File.binread(path, 200).to_s
        detail = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
        quarantine('unknown', [], reason: 'corrupt', detail: "#{detail}; first bytes: #{head.inspect}",
                                  source: File.basename(path))
      ensure
        delete(path)
      end

      # A crash between write and rename leaves "<name>.<hex>.tmp"; it was never
      # part of the queue, so it is removed rather than replayed.
      def sweep_temp_files
        [@dir, @qdir].each do |d|
          Dir.children(d).select { |n| n.end_with?('.tmp') }.each do |n|
            File.delete(File.join(d, n))
            @logger.warn("celerbrake-agent: removed an interrupted buffer write #{File.join(d, n)}")
          end
        end
      rescue SystemCallError => e
        @logger.warn("celerbrake-agent: could not sweep buffer temp files: #{e.class}: #{e.message}")
      end
    end
  end
end
