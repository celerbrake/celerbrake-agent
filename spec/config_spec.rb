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

  it 'loads host/project/scrape targets and interval from YAML' do
    yaml = <<~YML
      celerbrake:
        host: https://cb.example.com
        project_id: 7
        project_key: k3y
      scrape:
        - url: http://localhost:4000/api/metrics
          token: scrape-tok
      flush:
        interval: 20
    YML

    with_config(yaml) do |path|
      config = described_class.load(path)
      expect(config.host).to eq('https://cb.example.com')
      expect(config.project_id).to eq(7)
      expect(config.project_key).to eq('k3y')
      expect(config.scrape_targets.first).to eq(url: 'http://localhost:4000/api/metrics', token: 'scrape-tok', interval: nil)
      expect(config.interval).to eq(20)
      expect(config.validate!).to eq(config)
    end
  end

  it 'defaults the interval when unset' do
    with_config("celerbrake:\n  host: h\n  project_id: 1\n  project_key: k\n") do |path|
      expect(described_class.load(path).interval).to eq(described_class::DEFAULT_INTERVAL)
    end
  end

  it 'raises when a required field is missing' do
    with_config("scrape: []\n") do |path|
      expect { described_class.load(path).validate! }
        .to raise_error(ArgumentError, /missing required config/)
    end
  end
end
