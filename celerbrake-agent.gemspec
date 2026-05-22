require_relative 'lib/celerbrake/agent/version'

Gem::Specification.new do |s|
  s.name        = 'celerbrake-agent'
  s.version     = Celerbrake::Agent::VERSION
  s.summary     = 'Telemetry collector that ships app metrics and logs to Celerbrake'
  s.description = <<~DESC
    celerbrake-agent is a small, standalone collector process that runs alongside
    an app, scrapes its local Prometheus /api/metrics endpoint (and, soon, tails
    its JSON logs), and pushes the telemetry to a Celerbrake instance — authenticated
    with a project id + key, the same wiring as error reporting. It keeps the app's
    request path free of any telemetry network I/O (the Datadog-agent model).
  DESC
  s.author      = 'Celerbrake'
  s.email       = 'support@celerbrake.com'
  s.homepage    = 'https://github.com/celerbrake/celerbrake-agent'
  s.license     = 'MIT'

  s.require_path = 'lib'
  s.files        = Dir.glob('lib/**/*') + Dir.glob('bin/*') + Dir.glob('*.md')
  s.bindir       = 'bin'
  s.executables  = ['celerbrake-agent']

  s.required_ruby_version = '>= 3.0'
  s.metadata = { 'rubygems_mfa_required' => 'true' }

  # Runtime is otherwise stdlib-only (net/http, json, yaml, optparse, time).
  # logger left the default gem set on the road to Ruby 4.0; declare it.
  s.add_dependency 'logger', '~> 1.0'

  s.add_development_dependency 'rspec', '~> 3'
  s.add_development_dependency 'webmock', '~> 3'
  s.add_development_dependency 'rake', '~> 13'
end
