require 'spec_helper'

RSpec.describe Celerbrake::Agent::Client do
  let(:logger) { Logger.new(IO::NULL) }
  subject(:client) do
    described_class.new(host: 'https://cb.example.com', project_id: 7, project_key: 'k3y', logger: logger)
  end

  it 'posts samples with bearer auth and returns the accepted count' do
    stub = stub_request(:post, 'https://cb.example.com/api/v3/projects/7/metrics')
           .with(
             headers: { 'Authorization' => 'Bearer k3y', 'Content-Type' => 'application/json' }
           ) { |req| JSON.parse(req.body)['samples'].first['name'] == 'celerity_x_total' }
           .to_return(status: 202, body: '{"accepted":1}')

    count = client.push_metrics([{ name: 'celerity_x_total', type: 'counter', labels: {}, value: 1.0 }])

    expect(count).to eq(1)
    expect(stub).to have_been_requested
  end

  it 'posts log events to the logs endpoint' do
    stub = stub_request(:post, 'https://cb.example.com/api/v3/projects/7/logs')
           .to_return(status: 202, body: '{"accepted":1}')

    expect(client.push_logs([{ message: 'hi', level: 'info' }])).to eq(1)
    expect(stub).to have_been_requested
  end

  it 'raises Client::Error on a non-2xx response' do
    stub_request(:post, 'https://cb.example.com/api/v3/projects/7/logs').to_return(status: 401, body: 'nope')
    expect { client.push_logs([{ message: 'hi' }]) }
      .to raise_error(Celerbrake::Agent::Client::Error, /401/)
  end

  it 'no-ops on an empty batch (no HTTP call)' do
    expect(client.push_metrics([])).to eq(0)
    expect(client.push_logs(nil)).to eq(0)
  end
end
