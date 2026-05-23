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
      expect(c.scrape_targets.first).to eq(url: 'http://localhost:4000/api/metrics', token: 'scrape-tok', interval: nil)
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
end
