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

  it 'coerces binary-encoded payload strings to valid UTF-8 before serializing (json 3.0-safe)' do
    # Scraped Prometheus text and tailed log lines arrive ASCII-8BIT; without
    # coercion JSON.generate warns on json 2.x and raises on 3.0.
    msg = (+'café').force_encoding(Encoding::ASCII_8BIT)   # valid UTF-8 bytes, BINARY-tagged
    bad = (+"x\xFFy").force_encoding(Encoding::ASCII_8BIT) # genuinely invalid bytes

    stub = stub_request(:post, 'https://cb.example.com/api/v3/projects/7/logs')
           .with do |req|
             ev = JSON.parse(req.body)['events'].first
             ev['message'] == 'café' && ev['raw'].valid_encoding?
           end
           .to_return(status: 202, body: '{"accepted":1}')

    expect { client.push_logs([{ message: msg, raw: bad }]) }.not_to raise_error
    expect(stub).to have_been_requested
  end
end
