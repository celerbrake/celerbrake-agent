require 'spec_helper'

RSpec.describe Celerbrake::Agent::PrometheusParser do
  let(:exposition) do
    <<~PROM
      # TYPE celerity_user_signed_up_total counter
      # HELP celerity_user_signed_up_total Users who completed signup.
      celerity_user_signed_up_total 2.0
      # TYPE celerity_user_logged_in_total counter
      celerity_user_logged_in_total{method="password"} 1.0
      # TYPE celerity_job_duration_ms histogram
      celerity_job_duration_ms_bucket{job="DeliverEmailJob",le="10"} 0.0
      celerity_job_duration_ms_bucket{job="DeliverEmailJob",le="+Inf"} 1.0
      celerity_job_duration_ms_sum{job="DeliverEmailJob"} 42.0
      celerity_job_duration_ms_count{job="DeliverEmailJob"} 1.0
    PROM
  end

  it 'parses a bare counter' do
    counter = described_class.parse(exposition).find { |s| s[:name] == 'celerity_user_signed_up_total' }
    expect(counter).to include(type: 'counter', labels: {}, value: 2.0)
  end

  it 'parses labels (including multiple)' do
    sum = described_class.parse(exposition).find { |s| s[:name] == 'celerity_job_duration_ms_sum' }
    expect(sum[:labels]).to eq('job' => 'DeliverEmailJob')

    bucket = described_class.parse(exposition).find { |s| s[:labels]['le'] == '10' }
    expect(bucket[:labels]).to eq('job' => 'DeliverEmailJob', 'le' => '10')
  end

  it 'carries the histogram type onto each series via base-name lookup' do
    sum = described_class.parse(exposition).find { |s| s[:name] == 'celerity_job_duration_ms_sum' }
    count = described_class.parse(exposition).find { |s| s[:name] == 'celerity_job_duration_ms_count' }
    expect(sum[:type]).to eq('histogram')
    expect(count[:type]).to eq('histogram')
  end

  it 'keeps the +Inf bucket (the value is a normal count)' do
    inf = described_class.parse(exposition).find { |s| s[:labels]['le'] == '+Inf' }
    expect(inf[:value]).to eq(1.0)
  end

  it 'skips comments, blank lines, and HELP' do
    expect(described_class.parse("# HELP x foo\n\n   \n")).to eq([])
  end

  it 'returns [] for empty input' do
    expect(described_class.parse(nil)).to eq([])
    expect(described_class.parse('')).to eq([])
  end
end
