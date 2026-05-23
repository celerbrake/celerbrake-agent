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

  it 'forwards non-JSON lines as raw events instead of dropping them' do
    with_log do |f|
      tailer = described_class.new(path: f.path, logger: logger)
      tailer.read_new
      append(f, 'not json at all')
      expect(tailer.read_new.first).to include(source: 'raw', level: 'unknown', message: 'not json at all')
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
end
