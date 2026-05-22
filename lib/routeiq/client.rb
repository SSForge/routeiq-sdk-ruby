require "securerandom"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require_relative "version"
require_relative "handles"

module RouteIQ
  class Client
    attr_reader :session_id, :tracer

    def initialize(
      agent_id:,
      otlp_endpoint: "http://localhost:4317",
      tenant_id: "default",
      model: nil,
      environment: "production",
      agent_version: "1.0.0",
      api_key: nil
    )
      @agent_id      = agent_id
      @tenant_id     = tenant_id
      @model         = model
      @environment   = environment
      @agent_version = agent_version
      @session_id    = SecureRandom.uuid

      OpenTelemetry::SDK.configure do |c|
        c.service_name    = agent_id
        c.service_version = agent_version
        c.resource = OpenTelemetry::SDK::Resources::Resource.create(
          "routeiq.sdk.version" => RouteIQ::VERSION
        )
        c.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
            make_exporter(otlp_endpoint, api_key)
          )
        )
      end

      @tracer = OpenTelemetry.tracer_provider.tracer("routeiq.sdk", RouteIQ::VERSION)
    end

    def task(intent, task_type: nil, &block)
      handle = TaskHandle.new(self, intent, task_type: task_type)
      if block_given?
        begin
          block.call(handle)
          handle.complete unless handle.instance_variable_get(:@done)
        rescue => e
          handle.fail unless handle.instance_variable_get(:@done)
          raise
        ensure
          handle.end_span
        end
      else
        handle
      end
    end

    def flush
      OpenTelemetry.tracer_provider.force_flush
    end

    def envelope(task = nil, step = nil)
      attrs = {
        "routeiq.agent.id"    => @agent_id,
        "routeiq.tenant.id"   => @tenant_id,
        "routeiq.environment" => @environment,
        "routeiq.session.id"  => @session_id
      }
      if task
        attrs["routeiq.task.id"] = task.task_id
        attrs["routeiq.run.id"]  = task.run_id
      end
      attrs["routeiq.step.id"]                = step.step_id if step
      attrs["routeiq.version.model.name"]     = @model        if @model
      attrs["routeiq.version.agent"]          = @agent_version if @agent_version
      attrs
    end

    private

    def make_exporter(endpoint, api_key)
      headers = api_key ? {"authorization" => "Bearer #{api_key}"} : {}
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: endpoint,
        headers: headers
      )
    end
  end
end
