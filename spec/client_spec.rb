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

  describe 'classified failures' do
    let(:url) { 'https://cb.example.com/api/v3/projects/7/logs' }

    def failure_for(status, body: '', headers: {})
      stub_request(:post, url).to_return(status: status, body: body, headers: headers)
      client.push_logs([{ message: 'hi' }])
      nil
    rescue Celerbrake::Agent::Client::Error => e
      e
    end

    {
      413 => Celerbrake::Agent::Client::TooLarge,
      400 => Celerbrake::Agent::Client::Invalid,
      422 => Celerbrake::Agent::Client::Invalid,
      401 => Celerbrake::Agent::Client::Unauthorized,
      403 => Celerbrake::Agent::Client::Unauthorized,
      429 => Celerbrake::Agent::Client::RateLimited,
      500 => Celerbrake::Agent::Client::ServerError,
      503 => Celerbrake::Agent::Client::ServerError,
      404 => Celerbrake::Agent::Client::ServerError # unexpected statuses stay retryable
    }.each do |status, klass|
      it "raises #{klass.name.split('::').last} on #{status}, keeping the status and message format" do
        error = failure_for(status, body: 'nope')
        expect(error).to be_a(klass)
        expect(error).to be_a(Celerbrake::Agent::Client::Error)
        expect(error.status).to eq(status)
        expect(error.message).to eq("celerbrake-agent: POST /api/v3/projects/7/logs -> #{status}: nope")
      end
    end

    it "treats Celerbrake's 422 batch-too-large (item count over its cap) as TooLarge" do
      error = failure_for(422, body: '{"success":false,"reason":"batch-too-large","max":5000,"received":6000}')
      expect(error).to be_a(Celerbrake::Agent::Client::TooLarge)
      expect(error).to be_permanent
    end

    it 'parses Retry-After given in seconds' do
      error = failure_for(429, headers: { 'Retry-After' => '120' })
      expect(error).to be_a(Celerbrake::Agent::Client::RateLimited)
      expect(error.retry_after).to eq(120)
      expect(error).not_to be_permanent
    end

    it 'parses Retry-After given as an HTTP-date' do
      error = failure_for(503, headers: { 'Retry-After' => (Time.now + 60).httpdate })
      expect(error.retry_after).to be_between(58, 61)
    end

    it 'ignores a garbage Retry-After and clamps a huge one' do
      expect(described_class.parse_retry_after('soon')).to be_nil
      expect(described_class.parse_retry_after(nil)).to be_nil
      expect(described_class.parse_retry_after('86400')).to eq(described_class::MAX_RETRY_AFTER)
    end

    it 'raises Transport on a network failure or timeout' do
      stub_request(:post, url).to_timeout
      expect { client.push_logs([{ message: 'hi' }]) }
        .to raise_error(Celerbrake::Agent::Client::Transport, %r{POST /api/v3/projects/7/logs failed:}) { |e|
          expect(e.status).to be_nil
        }
    end
  end
end
