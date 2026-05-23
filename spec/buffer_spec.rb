require 'spec_helper'
require 'tmpdir'

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

  it 'drops the oldest batches when over the byte cap' do
    Dir.mktmpdir do |dir|
      buf = described_class.new(dir: dir, logger: logger, max_bytes: 50)
      buf.enqueue(:metrics, [{ a: 1 }])             # small
      buf.enqueue(:metrics, [{ a: 'x' * 100 }])     # pushes total over the cap
      buf.enqueue(:metrics, [{ a: 'y' * 100 }])     # prune runs before this write

      expect(buf.dropped).to be >= 1
    end
  end
end
