require 'spec_helper'
require 'tempfile'
require 'json'

RSpec.describe Celerbrake::Agent::LogTailer do
  let(:logger) { Logger.new(IO::NULL) }

  def with_log(initial = '')
    file = Tempfile.new(['app', '.log'])
    file.write(initial)
    file.flush
    yield file
  ensure
    file.close!
  end

  def append(file, obj)
    File.open(file.path, 'a') { |io| io.puts(obj.is_a?(String) ? obj : obj.to_json) }
  end

  it 'starts at end of file (skips history) then ships appended lines' do
    with_log("{\"message\":\"old\"}\n") do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      expect(tailer.read_new).to eq([]) # seek to end, skip the existing line

      append(f, time: '2026-05-22T00:00:00Z', level: 'info', message: 'new', request_id: 'r1')
      events = tailer.read_new
      expect(events.size).to eq(1)
      expect(events.first).to include(level: 'info', message: 'new', request_id: 'r1', source: 'app')
      expect(events.first[:ts]).to eq('2026-05-22T00:00:00Z')
    end
  end

  it 'maps a lograge-style request line (source=request, synth message, level from status)' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, method: 'GET', path: '/x', status: 500, time: 't', request_id: 'r2')
      ev = tailer.read_new.first
      expect(ev[:source]).to eq('request')
      expect(ev[:level]).to eq('error') # status >= 500
      expect(ev[:message]).to eq('GET /x -> 500')
    end
  end

  it 'forwards a prefix-less non-JSON line as a raw event instead of dropping it' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, 'not json at all')
      expect(tailer.read_new.first).to include(source: 'raw', level: 'unknown', message: 'not json at all')
    end
  end

  it 'lifts level + timestamp from a standard Ruby Logger prefix on a plain line' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, 'I, [2026-05-24T21:30:25.524387 #2527026]  INFO -- : [ActiveJob] Performed CleanupJob')
      ev = tailer.read_new.first
      expect(ev).to include(level: 'info', source: 'app', message: '[ActiveJob] Performed CleanupJob',
                            ts: '2026-05-24T21:30:25.524387')
    end
  end

  it 'parses JSON that follows a Logger prefix (e.g. db.slow_query), keeping its fields' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, 'I, [2026-05-24T21:30:25.5 #99]  INFO -- : {"event":"db.slow_query","duration_ms":150,"fingerprint":"abc","request_id":"r9"}')
      ev = tailer.read_new.first
      expect(ev[:fields]['event']).to eq('db.slow_query')
      expect(ev[:level]).to eq('info')
      expect(ev[:request_id]).to eq('r9')
    end
  end

  it 'maps WARN/ERROR prefixes to their levels' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, 'W, [2026-05-24T21:30:26.0 #99]  WARN -- : disk getting full')
      expect(tailer.read_new.first).to include(level: 'warn', message: 'disk getting full')
    end
  end

  it 'does not emit a partial (newline-less) trailing line until it completes' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      File.open(f.path, 'a') { |io| io.write('{"message":"partial"}') } # no newline yet
      expect(tailer.read_new).to eq([])
      File.open(f.path, 'a') { |io| io.write("\n") } # complete the line
      expect(tailer.read_new.first).to include(message: 'partial')
    end
  end

  describe 'tagged-logging brackets + synthesized messages (the #6 fix)' do
    # A standard Ruby Logger line wrapping the given (already-tagged) payload.
    def prefixed(payload, sev: 'INFO')
      "#{sev[0]}, [2026-05-25T01:20:06.595 #99]  #{sev} -- : #{payload}"
    end

    it 'strips a [request_id] tag off a lograge request line and still parses the JSON' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        json = { method: 'GET', path: '/api/metrics', status: 200,
                 request_id: '6f13a452-58cb-4fc4-bdbc-5f3d937b4207' }.to_json
        append(f, prefixed("[6f13a452-58cb-4fc4-bdbc-5f3d937b4207] #{json}"))
        ev = tailer.read_new.first
        expect(ev[:source]).to eq('request')
        expect(ev[:message]).to eq('GET /api/metrics -> 200')        # not a raw JSON dump
        expect(ev[:fields]['method']).to eq('GET')                   # JSON parsed into fields
        expect(ev[:request_id]).to eq('6f13a452-58cb-4fc4-bdbc-5f3d937b4207')
      end
    end

    it 'strips [ActiveJob][JobClass][job_id] tags off an in-job line and lifts job_id as the correlation id' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        json = { event: 'coinbase_api.request', account_id: 1 }.to_json
        append(f, prefixed("[ActiveJob] [ReconcileFillsJob] [33e459ab-d969-4345-81c2-5db8dca91264] #{json}"))
        ev = tailer.read_new.first
        expect(ev[:source]).to eq('job')
        expect(ev[:fields]['event']).to eq('coinbase_api.request')   # parsed, not raw
        expect(ev[:message]).to eq('coinbase_api.request')
        expect(ev[:request_id]).to eq('33e459ab-d969-4345-81c2-5db8dca91264')
      end
    end

    it 'synthesizes a readable message for a structured job line (no message key)' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        json = { event: 'job.perform', job: 'ReconcileFillsJob', duration_ms: 12.5, status: 'ok' }.to_json
        append(f, prefixed("[ActiveJob] [ReconcileFillsJob] [33e459ab-d969-4345-81c2-5db8dca91264] #{json}"))
        ev = tailer.read_new.first
        expect(ev[:message]).to eq('job.perform ReconcileFillsJob (12.5ms)')
        expect(ev[:source]).to eq('job')
      end
    end

    it 'appends the status when a job line failed' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        json = { event: 'job.discard', job: 'ReconcileFillsJob', status: 'error',
                 exception_class: 'RuntimeError' }.to_json
        append(f, prefixed("[ActiveJob] [ReconcileFillsJob] [33e459ab-d969-4345-81c2-5db8dca91264] #{json}", sev: 'ERROR'))
        ev = tailer.read_new.first
        expect(ev[:message]).to eq('job.discard ReconcileFillsJob error')
        expect(ev[:level]).to eq('error')                            # exception_class -> error
      end
    end

    it 'synthesizes a message for a metric line (previously rendered blank)' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        append(f, metric: 'ws.tick', type: 'counter', value: 1) # pure JSON, no prefix/tags
        ev = tailer.read_new.first
        expect(ev[:message]).to eq('metric ws.tick=1')
        expect(ev[:source]).to eq('app')
      end
    end

    it 'keeps a plain (non-JSON) tagged line verbatim — tags are not stripped from a message' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        append(f, prefixed('[ActiveJob] [CleanupJob] [abc] Performed CleanupJob in 3ms'))
        ev = tailer.read_new.first
        expect(ev[:message]).to eq('[ActiveJob] [CleanupJob] [abc] Performed CleanupJob in 3ms')
        expect(ev[:fields]).to eq({})
      end
    end

    it 'does not mistake a non-UUID tag for a request_id' do
      with_log do |f|
        tailer = described_class.new(path: f.path, logger: logger)
        tailer.read_new
        append(f, prefixed("[ActiveJob] #{{ event: 'job.enqueue', job: 'X' }.to_json}"))
        ev = tailer.read_new.first
        expect(ev[:request_id]).to be_nil
        expect(ev[:message]).to eq('job.enqueue X')
        expect(ev[:source]).to eq('job')
      end
    end
  end
end
