require 'spec_helper'
require 'tmpdir'
require 'stringio'

RSpec.describe Celerbrake::Agent::Buffer do
  let(:logger) { Logger.new(IO::NULL) }

  it 'enqueues, replays oldest-first, and deletes batches' do
    Dir.mktmpdir do |dir|
      buf = described_class.new(dir: dir, logger: logger)
      buf.enqueue(:metrics, [{ name: 'a' }])
      buf.enqueue(:logs, [{ message: 'b' }])

      seen = []
      buf.each_batch { |kind, items, path| seen << [kind, items]; buf.delete(path) }

      expect(seen).to eq([['metrics', [{ 'name' => 'a' }]], ['logs', [{ 'message' => 'b' }]]])
      expect(buf.size_bytes).to eq(0)
    end
  end

  it 'drops the oldest batches when over the byte cap, accounting for the incoming batch' do
    Dir.mktmpdir do |dir|
      buf = described_class.new(dir: dir, logger: logger, max_bytes: 300)
      buf.enqueue(:metrics, [{ a: 'x' * 100 }])
      buf.enqueue(:metrics, [{ a: 'y' * 100 }])
      expect(buf.dropped).to eq(0)
      buf.enqueue(:metrics, [{ a: 'z' * 100 }]) # would make three: the oldest goes first

      expect(buf.dropped).to eq(1)
      expect(buf.size_bytes).to be <= 300
      kept = []
      buf.each_batch { |_kind, items, _path| kept << items.first['a'][0] }
      expect(kept).to eq(%w[y z])
    end
  end
end

RSpec.describe Celerbrake::Agent::Buffer, 'disk policy' do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

  def spooled
    Dir.children(@dir).grep(/\.json\z/).sort
  end

  def quarantined_entries
    q = File.join(@dir, 'quarantine')
    Dir.children(q).sort.map { |n| JSON.parse(File.read(File.join(q, n))) }
  end

  it 'splits an oversized batch at enqueue and stays within max_bytes' do
    buf = described_class.new(dir: @dir, logger: logger, max_bytes: 2_000, max_batch_bytes: 300)
    items = Array.new(30) { |i| { message: format('%03d', i) + ('x' * 60) } } # ~2.4KB total

    expect(buf.enqueue(:logs, items)).to be(true)

    sizes = spooled.map { |n| File.size(File.join(@dir, n)) }
    expect(sizes.size).to be > 1
    expect(sizes).to all(be <= 300)
    expect(buf.size_bytes).to be <= 2_000 # the oldest slices were dropped to make room
    expect(buf.dropped).to be >= 1

    kept = []
    buf.each_batch { |_k, its, _p| kept.concat(its.map { |e| e['message'][0, 3].to_i }) }
    expect(kept).to eq(kept.sort) # order preserved
    expect(kept.last).to eq(29)   # the newest survive
  end

  it 'quarantines a single item that is larger than max_batch_bytes instead of spooling it' do
    buf = described_class.new(dir: @dir, logger: logger, max_bytes: 10_000, max_batch_bytes: 200)
    buf.enqueue(:logs, [{ message: 'ok' }, { message: 'y' * 500 }])

    expect(buf.quarantined).to eq(1)
    expect(quarantined_entries.first).to include('reason' => 'item-too-large', 'item_count' => 1, 'kind' => 'logs')
    remaining = []
    buf.each_batch { |_k, its, _p| remaining.concat(its) }
    expect(remaining).to eq([{ 'message' => 'ok' }])
  end

  it 'writes atomically: a failed write leaves neither a partial batch nor a temp file' do
    buf = described_class.new(dir: @dir, logger: logger)
    allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

    expect(buf.enqueue(:logs, [{ message: 'a' }])).to be(false) # the caller keeps the data
    expect(Dir.children(@dir) - ['quarantine']).to be_empty
    expect(log_io.string).to include('buffer write failed')
  end

  it 'sweeps a half-written temp file left by a crash and never replays it' do
    name = format('%020d-abcdef.json', 1)
    File.write(File.join(@dir, "#{name}.1234abcd.tmp"), '{"kind":"logs","items":[{"mess') # interrupted write
    buf = described_class.new(dir: @dir, logger: logger, max_bytes: 1_000)

    expect(Dir.children(@dir)).to eq(['quarantine'])
    expect(buf.size_bytes).to eq(0)
    seen = []
    buf.each_batch { |*args| seen << args }
    expect(seen).to be_empty
  end

  it 'moves an unreadable batch to quarantine with reason "corrupt" and keeps replaying the rest' do
    buf = described_class.new(dir: @dir, logger: logger)
    File.write(File.join(@dir, format('%020d-0bad.json', 1)), '{"kind":"logs","ite')
    buf.enqueue(:logs, [{ message: 'good' }])

    seen = []
    buf.each_batch { |_k, items, path| seen << items; buf.delete(path) }
    expect(seen).to eq([[{ 'message' => 'good' }]])
    expect(quarantined_entries.map { |e| e['reason'] }).to eq(['corrupt'])
    expect(buf.quarantined).to eq(1)
  end

  it 'ignores files that are not spooled batches (a cursor file in the same dir)' do
    File.write(File.join(@dir, 'cursor.json'), '{"version":1,"files":{}}')
    buf = described_class.new(dir: @dir, logger: logger)
    seen = []
    buf.each_batch { |*args| seen << args }
    expect(seen).to be_empty
    expect(File).to exist(File.join(@dir, 'cursor.json'))
  end

  it 'replaces a batch with its pending pieces in the same replay position' do
    buf = described_class.new(dir: @dir, logger: logger)
    buf.enqueue(:logs, [{ m: 1 }, { m: 2 }, { m: 3 }])
    buf.enqueue(:logs, [{ m: 9 }])
    first = nil
    buf.each_batch { |_k, _i, path| first ||= path }

    buf.replace(first, :logs, [[{ m: 2 }], [{ m: 3 }]])

    order = []
    buf.each_batch { |_k, items, _p| order.concat(items.map { |i| i['m'] }) }
    expect(order).to eq([2, 3, 9])
  end

  it 'caps the quarantine directory, pruning the oldest entries' do
    buf = described_class.new(dir: @dir, logger: logger, quarantine_max_bytes: 600)
    buf.quarantine(:logs, [{ message: 'z' * 1_000 }], reason: 'invalid', detail: '400 bad')
    4.times { |i| buf.quarantine(:logs, [{ message: "q#{i}" * 20 }], reason: 'invalid', detail: '400') }

    expect(buf.quarantined).to eq(5)
    expect(buf.quarantine_bytes).to be <= 600
    entries = quarantined_entries
    expect(entries.last['items'].first['message']).to start_with('q3') # newest kept, oldest pruned
  end

  it 'stores a stub with the reason and item count when the quarantined batch exceeds the cap' do
    buf = described_class.new(dir: @dir, logger: logger, quarantine_max_bytes: 600)
    buf.quarantine(:logs, [{ message: 'z' * 1_000 }, { message: 'w' }], reason: 'invalid', detail: '400 bad')

    entry = quarantined_entries.first
    expect(entry).to include('reason' => 'invalid', 'item_count' => 2, 'items' => [], 'detail' => '400 bad')
    expect(entry['items_omitted_bytes']).to be > 600
  end
end
