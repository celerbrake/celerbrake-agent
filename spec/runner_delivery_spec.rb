require 'spec_helper'
require 'tmpdir'
require 'stringio'

# Delivery policy and the durable collection path (review findings R04, R05).
RSpec.describe Celerbrake::Agent::Runner, 'delivery policy' do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:logs_url) { 'https://cb.example.com/api/v3/projects/5/logs' }
  let(:metrics_url) { 'https://cb.example.com/api/v3/projects/5/metrics' }
  let(:clock) { [1_000.0] }
  let(:extra_config) { {} }

  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      @log = File.join(dir, 'production.log')
      @buffer_dir = File.join(dir, 'buffer')
      File.write(@log, '')
      ex.run
    end
  end

  def config(**overrides)
    Celerbrake::Agent::Config.new(
      host: 'https://cb.example.com', project_id: 5, project_key: 'k',
      log_paths: [@log], buffer_dir: @buffer_dir, **extra_config, **overrides
    )
  end

  def new_runner(**overrides)
    described_class.new(config: config(**overrides), logger: logger, clock: -> { clock[0] }, rng: Random.new(1))
  end

  def write(*lines)
    File.open(@log, 'a') { |io| lines.each { |l| io.puts(%({"message":"#{l}"})) } }
  end

  def spooled
    Dir.children(@buffer_dir).grep(/\.json\z/).sort
  end

  # Log events in the spool (self-metrics batches are spooled too while waiting).
  def spooled_messages
    spooled.map { |n| JSON.parse(File.read(File.join(@buffer_dir, n))) }
           .select { |b| b['kind'] == 'logs' }
           .flat_map { |b| b['items'] }.map { |e| e['message'] }
  end

  def quarantine
    q = File.join(@buffer_dir, 'quarantine')
    Dir.children(q).sort.map { |n| JSON.parse(File.read(File.join(q, n))) }
  end

  def later!(seconds = described_class::MAX_BACKOFF + 1)
    clock[0] += seconds
  end

  # Records every delivered log message; the block decides the response.
  def stub_logs(&responder)
    delivered = []
    stub_request(:post, logs_url).to_return do |req|
      events = JSON.parse(req.body)['events']
      response = responder ? responder.call(events) : { status: 202 }
      delivered.concat(events.map { |e| e['message'] }) if response[:status] == 202
      response
    end
    delivered
  end

  before { stub_request(:post, metrics_url).to_return(status: 202) }

  describe 'restarts' do
    it 'loses no line when the agent restarts between read and spool' do
      delivered = stub_logs
      first = new_runner
      first.run_once # first run: tail from the end, cursor saved
      write('a', 'b')
      first.send(:instance_variable_get, :@tailers).first.read_new # read, then crash before deliver

      new_runner.run_once
      expect(delivered).to eq(%w[a b])
    end

    it 'loses no line when the agent restarts between spool and send, and does not re-read it' do
      down = true
      delivered = stub_logs { down ? { status: 503 } : { status: 202 } }
      first = new_runner
      first.run_once
      write('a', 'b')
      first.run_once # backend down: spooled, cursor committed
      expect(spooled_messages).to eq(%w[a b])

      down = false
      new_runner.run_once # restarted process replays the spool
      expect(delivered).to eq(%w[a b]) # exactly once: the cursor is past them
      expect(spooled).to be_empty
    end

    it 'keeps the lines in the log when the spool cannot be written, and ships them later' do
      down = true
      delivered = stub_logs { down ? { status: 503 } : { status: 202 } }
      runner = new_runner
      runner.run_once
      write('a')
      buffer = runner.instance_variable_get(:@buffer)
      allow(buffer).to receive(:enqueue).and_return(false) # disk full
      runner.run_once
      expect(delivered).to be_empty

      allow(buffer).to receive(:enqueue).and_call_original
      down = false
      later!
      runner.run_once
      expect(delivered).to eq(['a']) # the tailer rewound, so the line was read again
    end
  end

  describe 'permanent failures' do
    it 'splits a batch on 413 so the valid part delivers, quarantining the single oversized item' do
      delivered = stub_logs do |events|
        events.any? { |e| e['message'] == 'poison' } ? { status: 413, body: 'too big' } : { status: 202 }
      end
      runner = new_runner
      runner.run_once
      write('a', 'b', 'c', 'poison')
      result = runner.run_once

      expect(delivered).to contain_exactly('a', 'b', 'c')
      expect(result[:logs]).to eq(3)
      expect(quarantine.map { |q| [q['reason'], q['item_count']] }).to eq([['too-large', 1]])
      expect(spooled).to be_empty
    end

    it 'bounds the split requests when everything gets 413, spooling the rest and backing off' do
      stub_logs { { status: 413 } }
      runner = new_runner
      runner.run_once
      write(*Array.new(500) { |i| "l#{i}" })
      runner.run_once

      expect(a_request(:post, logs_url)).to have_been_made.times(described_class::MAX_SPLIT_REQUESTS)
      expect(spooled_messages.size + quarantine.sum { |q| q['item_count'] }).to eq(500) # nothing lost
      expect(runner.instance_variable_get(:@retry_at)).not_to be_nil
    end

    it 'quarantines a spooled batch that gets 400 and replays the next one in the same tick' do
      phase = :down
      delivered = stub_logs do |events|
        next { status: 503 } if phase == :down

        events.any? { |e| e['message'] == 'bad' } ? { status: 400, body: 'invalid' } : { status: 202 }
      end
      runner = new_runner
      runner.run_once
      write('bad')
      runner.run_once
      later!
      write('good')
      runner.run_once # still down: two spooled batches, the bad one first
      expect(spooled.size).to be >= 2

      phase = :up
      later!
      runner.run_once
      expect(delivered).to eq(['good'])
      expect(quarantine.map { |q| q['reason'] }).to eq(['invalid'])
      expect(spooled).to be_empty
    end

    it 'does not spool a fresh batch that gets 422' do
      stub_logs { { status: 422, body: '{"reason":"empty-or-malformed-batch"}' } }
      runner = new_runner
      runner.run_once
      write('x')
      runner.run_once
      expect(spooled).to be_empty
      expect(quarantine.first).to include('reason' => 'invalid', 'item_count' => 1)
    end
  end

  describe 'transient failures' do
    it 'honours Retry-After on 429: no request until it passes, then replays' do
      responses = [{ status: 429, headers: { 'Retry-After' => '120' } }]
      delivered = stub_logs { responses.shift || { status: 202 } }
      runner = new_runner
      runner.run_once
      write('a')
      runner.run_once
      expect(spooled_messages).to eq(['a'])
      expect(log_io.string).to include('next attempt in 120.0s')

      later!(60)
      write('b')
      runner.run_once
      expect(a_request(:post, logs_url)).to have_been_made.once # still waiting: nothing sent
      expect(spooled_messages).to eq(%w[a b])

      later!(61)
      runner.run_once
      expect(delivered).to eq(%w[a b])
      expect(spooled).to be_empty
    end

    it 'keeps the spool through repeated 5xx and backs off within 1s..5min' do
      stub_request(:post, logs_url).to_return(status: 503)
      stub_request(:post, metrics_url).to_return(status: 503)
      runner = new_runner
      runner.run_once
      write('a')
      delays = []
      8.times do
        runner.run_once
        retry_at = runner.instance_variable_get(:@retry_at)
        delays << retry_at - clock[0]
        later!
      end
      expect(spooled_messages).to include('a')
      expect(delays).to all(be_between(described_class::MIN_BACKOFF, described_class::MAX_BACKOFF))
      expect(delays.last).to be > delays.first # exponential growth
    end

    it 'logs a refused key once per state change and counts every auth failure' do
      key_ok = false
      delivered = stub_logs { key_ok ? { status: 202 } : { status: 401, body: 'bad key' } }
      stub_request(:post, metrics_url).to_return { key_ok ? { status: 202 } : { status: 401 } }
      runner = new_runner
      runner.run_once
      write('a')
      3.times do
        runner.run_once
        later!
      end
      expect(log_io.string.scan('the project key was refused').size).to eq(1)
      expect(runner.auth_failures).to be >= 3
      expect(spooled_messages).to include('a') # spooled for when the key is fixed

      key_ok = true
      runner.run_once
      expect(delivered).to include('a')
      expect(log_io.string).to include('accepts the project key again')
    end

    it 'keeps the spool within max_bytes through a sustained outage' do
      stub_request(:post, logs_url).to_return(status: 503)
      stub_request(:post, metrics_url).to_return(status: 503)
      runner = new_runner(buffer_max_bytes: 4_000, buffer_max_batch_bytes: 1_000)
      buffer = runner.instance_variable_get(:@buffer)
      runner.run_once
      20.times do |i|
        write(*Array.new(10) { |j| "line-#{i}-#{j}-#{'x' * 40}" })
        runner.run_once
        expect(buffer.size_bytes).to be <= 4_000
        later!
      end
      expect(buffer.dropped).to be > 0
    end
  end

  describe 'replay budget' do
    def seed_spool(count)
      buffer = Celerbrake::Agent::Buffer.new(dir: @buffer_dir, logger: logger)
      count.times { |i| buffer.enqueue(:logs, [{ message: "spooled-#{i}" }]) }
    end

    it 'stops after max_batches per tick and resumes on the next tick' do
      seed_spool(5)
      delivered = stub_logs
      runner = new_runner(replay_max_batches: 2)

      expect(runner.run_once[:replayed]).to eq(2)
      expect(spooled.size).to eq(3)
      expect(runner.run_once[:replayed]).to eq(2)
      expect(runner.run_once[:replayed]).to eq(1)
      expect(delivered).to eq(Array.new(5) { |i| "spooled-#{i}" })
    end

    it 'stops after max_bytes per tick' do
      seed_spool(4)
      stub_logs
      one = File.size(File.join(@buffer_dir, spooled.first))
      runner = new_runner(replay_max_bytes: (one * 2) + 1)
      expect(runner.run_once[:replayed]).to eq(2)
    end

    it 'stops after max_seconds per tick so fresh collection continues' do
      seed_spool(4)
      delivered = stub_logs do |events|
        clock[0] += 3 if events.first['message'].start_with?('spooled') # each replay "takes" 3s
        { status: 202 }
      end
      runner = new_runner(replay_max_seconds: 5)
      runner.run_once # tails from end
      write('fresh')
      result = runner.run_once
      expect(result[:replayed]).to be < 4
      expect(delivered).to include('fresh')
    end
  end
end
