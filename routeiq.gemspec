require_relative "lib/routeiq/version"

Gem::Specification.new do |spec|
  spec.name        = "routeiq-sdk"
  spec.version     = RouteIQ::VERSION
  spec.summary     = "RouteIQ SDK — instrument AI agents with task/step/tool spans"
  spec.authors     = ["RouteIQ"]
  spec.files       = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "opentelemetry-sdk", "~> 1.4"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.28"

  spec.add_development_dependency "minitest"
end
