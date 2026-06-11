require 'spec_helper'
require 'tmpdir'

RSpec.describe Celerbrake::Agent::Runner do
  let(:logger) { Logger.new(IO::NULL) }

  around do |example|
    Dir.mktmpdir { |dir| @buffer_dir = dir; example.run }
  end

  let(:config) do
    Celerbrake::Agent::Config.new(
      host: 'https://cb.example.com', project_id: 5, project_key: 'k',
      scrape_targets: [{ url: 'https://app.example.com/api/metrics', token: 't' }],
      buffer_dir: @buffer_dir
    )
  end
  subject(:runner) { described_class.new(config: config, logger: logger) }

  before do
    stub_request(:get, 'https://app.example.com/api/metrics')
      .to_return(status: 200, body: "# TYPE x_total counter\nx_total 1.0\n")
  end

  def buffered_files
    Dir.glob(File.join(@buffer_dir, '*.json'))
  end

  it 'buffers a batch when the push fails, then replays it once the backend recovers' do
    stub_request(:post, 'https://cb.example.com/api/v3/projects/5/metrics')
      .to_return(status: 503).times(2).then
      .to_return(status: 202, body: '{"accepted":1}')

    first = runner.run_once
    expect(first[:metrics]).to eq(0)        # delivery failed
    expect(buffered_files.size).to eq(2)    # scrape batch + the agent's self-metrics batch

    second = runner.run_once
    expect(second[:replayed]).to be >= 1    # buffered batch replayed
    expect(buffered_files).to be_empty
  end

  it 'delivers cleanly when the backend is up' do
    stub_request(:post, 'https://cb.example.com/api/v3/projects/5/metrics')
      .to_return(status: 202, body: '{"accepted":1}')

    result = runner.run_once
    expect(result[:metrics]).to eq(3) # 1 scraped sample + 2 agent self-metrics
    expect(buffered_files).to be_empty
  end

  it "pushes the agent's own health metrics every tick (drops + buffer bytes)" do
    pushed = []
    stub_request(:post, 'https://cb.example.com/api/v3/projects/5/metrics')
      .to_return do |req|
        pushed.concat(JSON.parse(req.body)['samples'])
        { status: 202, body: '{"accepted":1}' }
      end

    runner.run_once

    names = pushed.map { |m| m['name'] }
    expect(names).to include('celerbrake_agent_dropped_batches_total', 'celerbrake_agent_buffer_bytes')
    drop = pushed.find { |m| m['name'] == 'celerbrake_agent_dropped_batches_total' }
    expect(drop['value']).to eq(0.0) # healthy agent — series exists at zero
    expect(drop['type']).to eq('counter')
  end
end
