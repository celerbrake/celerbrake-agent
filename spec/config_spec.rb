require 'spec_helper'
require 'tempfile'

RSpec.describe Celerbrake::Agent::Config do
  def with_config(yaml)
    file = Tempfile.new(['agent', '.yml'])
    file.write(yaml)
    file.flush
    yield file.path
  ensure
    file.close!
  end

  it 'loads host/project/scrape/logs/buffer/interval from YAML' do
    yaml = <<~YML
      celerbrake:
        host: https://cb.example.com
        project_id: 7
        project_key: k3y
      scrape:
        - url: http://localhost:4000/api/metrics
          token: scrape-tok
      logs:
        - path: log/production.log
      flush:
        interval: 20
      buffer:
        dir: tmp/agent-buf
        max_bytes: 5000
    YML

    with_config(yaml) do |path|
      c = described_class.load(path)
      expect(c.host).to eq('https://cb.example.com')
      expect(c.project_id).to eq(7)
      expect(c.project_key).to eq('k3y')
      expect(c.scrape_targets.first).to eq(url: 'http://localhost:4000/api/metrics', token: 'scrape-tok')
      expect(c.log_paths).to eq(['log/production.log'])
      expect(c.interval).to eq(20)
      expect(c.buffer_dir).to eq('tmp/agent-buf')
      expect(c.buffer_max_bytes).to eq(5000)
      expect(c.validate!).to eq(c)
    end
  end

  it 'defaults interval/buffer when unset and has no log paths' do
    with_config("celerbrake:\n  host: h\n  project_id: 1\n  project_key: k\n") do |path|
      c = described_class.load(path)
      expect(c.interval).to eq(described_class::DEFAULT_INTERVAL)
      expect(c.buffer_dir).to eq(described_class::DEFAULT_BUFFER_DIR)
      expect(c.log_paths).to eq([])
    end
  end

  it 'raises when a required field is missing' do
    with_config("scrape: []\n") do |path|
      expect { described_class.load(path).validate! }
        .to raise_error(ArgumentError, /missing required config/)
    end
  end

  it 'loads the state dir, batch limit, quarantine cap and replay budget' do
    yaml = <<~YML
      celerbrake: { host: h, project_id: 1, project_key: k }
      buffer:
        dir: /rails/log/celerbrake-agent/buffer
        max_bytes: 100000000
        max_batch_bytes: 2000000
        quarantine_max_bytes: 5000000
        replay: { max_batches: 7, max_bytes: 9000000, max_seconds: 4 }
      state:
        dir: /rails/log/celerbrake-agent/state
      something_new: ignored
    YML

    with_config(yaml) do |path|
      c = described_class.load(path)
      expect(c.state_dir).to eq('/rails/log/celerbrake-agent/state')
      expect(c.buffer_max_batch_bytes).to eq(2_000_000)
      expect(c.quarantine_max_bytes).to eq(5_000_000)
      expect([c.replay_max_batches, c.replay_max_bytes, c.replay_max_seconds]).to eq([7, 9_000_000, 4.0])
    end
  end

  it 'defaults the state dir to <buffer.dir>/state for config files written before it existed' do
    with_config("celerbrake: { host: h, project_id: 1, project_key: k }\nbuffer:\n  dir: /data/buf\n") do |path|
      c = described_class.load(path)
      expect(c.state_dir).to eq('/data/buf/state')
      expect(c.buffer_max_batch_bytes).to eq(described_class::DEFAULT_MAX_BATCH_BYTES)
      expect(c.replay_max_batches).to eq(described_class::DEFAULT_REPLAY_MAX_BATCHES)
      expect(c.replay_max_bytes).to eq(described_class::DEFAULT_REPLAY_MAX_BYTES)
      expect(c.replay_max_seconds).to eq(described_class::DEFAULT_REPLAY_MAX_SECONDS)
    end
    with_config("celerbrake: { host: h, project_id: 1, project_key: k }\n") do |path|
      expect(described_class.load(path).state_dir).to eq(File.join(described_class::DEFAULT_BUFFER_DIR, 'state'))
    end
  end
end
