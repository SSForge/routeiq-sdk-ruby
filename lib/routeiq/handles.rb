require "digest"
require "json"
require "opentelemetry/sdk"

module RouteIQ
  COMPLETION_SUCCESS = "1"
  COMPLETION_FAILURE = "2"
  TOOL_SUCCESS = "1"
  TOOL_FAILURE = "2"

  PERMISSION = {
    "READ_ONLY"  => "1",
    "READ_WRITE" => "2",
    "PRIVILEGED" => "3"
  }.freeze

  # ── ToolHandle ──────────────────────────────────────────────────────────────

  class ToolHandle
    def initialize(step, name, args: {}, permission: "READ_ONLY")
      @step       = step
      @name       = name
      @args       = args
      @permission = permission
      @start      = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @done       = false

      args_hash = Digest::SHA256.hexdigest(JSON.generate(args.sort.to_h))[0, 16]
      perm      = PERMISSION.fetch(permission, "1")
      riq       = step.task.riq

      @span = riq.tracer.start_span("tool:#{name}", attributes: {
        "routeiq.event.type"             => "7",
        **riq.envelope(step.task, step),
        "routeiq.tool.name"              => name,
        "routeiq.tool.arguments_hash"    => args_hash,
        "routeiq.tool.permission_level"  => perm
      })
    end

    def success(latency_ms: nil)
      finish(TOOL_SUCCESS, latency_ms: latency_ms)
    end

    def fail(error_code: "", latency_ms: nil)
      finish(TOOL_FAILURE, error_code: error_code, latency_ms: latency_ms)
    end

    def end_span
      @span.finish unless @span.nil?
    end

    private

    def finish(status, error_code: "", latency_ms: nil)
      return if @done
      @done = true
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start) * 1000
      attrs = {
        "routeiq.tool.result_status" => status,
        "routeiq.tool.latency_ms"    => latency_ms || elapsed
      }
      attrs["routeiq.tool.error_code"] = error_code unless error_code.empty?
      @span&.add_attributes(attrs)
    end
  end

  # ── StepHandle ──────────────────────────────────────────────────────────────

  class StepHandle
    attr_reader :step_id, :task

    def initialize(task, action: nil, rationale: nil, index: 1)
      @task     = task
      @step_id  = SecureRandom.uuid
      @done     = false
      riq       = task.riq

      attrs = {
        "routeiq.event.type"  => "4",
        **riq.envelope(task, self),
        "routeiq.step.index"  => index
      }
      attrs["routeiq.step.selected_action"]   = action    if action
      attrs["routeiq.step.action_rationale"]  = rationale if rationale

      @span = riq.tracer.start_span("step:#{@step_id}", attributes: attrs)
    end

    def tool(name, args: {}, permission: "READ_ONLY", &block)
      handle = ToolHandle.new(self, name, args: args, permission: permission)
      if block_given?
        begin
          block.call(handle)
          handle.success unless handle.instance_variable_get(:@done)
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

    def complete
      finish(COMPLETION_SUCCESS)
    end

    def fail(category: "")
      finish(COMPLETION_FAILURE, failure_category: category)
    end

    def end_span
      @span.finish unless @span.nil?
    end

    private

    def finish(status, failure_category: "")
      return if @done
      @done = true
      attrs = {"routeiq.step.completion_status" => status}
      attrs["routeiq.step.failure_category"] = failure_category unless failure_category.empty?
      @span&.add_attributes(attrs)
    end
  end

  # ── TaskHandle ──────────────────────────────────────────────────────────────

  class TaskHandle
    attr_reader :task_id, :run_id, :riq

    def initialize(riq, intent, task_type: nil)
      @riq         = riq
      @intent      = intent
      @task_type   = task_type
      @task_id     = SecureRandom.uuid
      @run_id      = SecureRandom.uuid
      @done        = false
      @step_index  = 0

      attrs = {
        "routeiq.event.type"        => "1",
        **riq.envelope(self),
        "routeiq.task.input_intent" => intent[0, 256]
      }
      attrs["routeiq.task.type"] = task_type if task_type

      @span = riq.tracer.start_span("task:#{@task_id}", attributes: attrs)
    end

    def step(action: nil, rationale: nil, &block)
      @step_index += 1
      handle = StepHandle.new(self, action: action, rationale: rationale, index: @step_index)
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

    def complete(tokens: 0, cost_usd: nil, cohort: nil)
      finish(COMPLETION_SUCCESS, tokens: tokens, cost_usd: cost_usd, cohort: cohort)
    end

    def fail(category: "")
      finish(COMPLETION_FAILURE, failure_category: category)
    end

    def end_span
      @span.finish unless @span.nil?
    end

    private

    def finish(status, tokens: 0, cost_usd: nil, cohort: nil, failure_category: "")
      return if @done
      @done = true
      attrs = {"routeiq.task.completion_status" => status}
      attrs["routeiq.task.total_tokens"]      = tokens       if tokens > 0
      attrs["routeiq.task.cost_usd"]          = cost_usd     if cost_usd
      attrs["routeiq.task.cohort"]            = cohort        if cohort
      attrs["routeiq.task.failure_category"]  = failure_category unless failure_category.empty?
      @span&.add_attributes(attrs)
    end
  end
end
