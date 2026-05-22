$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'logger'
require 'json'
require 'celerbrake/agent'
require 'webmock/rspec'

RSpec.configure do |c|
  c.disable_monkey_patching!
  c.order = :random
  c.expect_with(:rspec) { |e| e.syntax = :expect }
end

WebMock.disable_net_connect!
