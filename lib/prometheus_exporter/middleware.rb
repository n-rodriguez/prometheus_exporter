# frozen_string_literal: true

require "prometheus_exporter/instrumentation/method_profiler"
require "prometheus_exporter/client"

class PrometheusExporter::Middleware
  MethodProfiler = PrometheusExporter::Instrumentation::MethodProfiler

  def initialize(app, config = { instrument: :alias_method, client: nil })
    @app = app
    @client = config[:client] || PrometheusExporter::Client.default

    if config[:instrument]
      apply_redis_client_middleware! if defined?(RedisClient)

      if defined?(Redis::VERSION) && (Gem::Version.new(Redis::VERSION) >= Gem::Version.new("5.0.0"))
        # redis 5 support handled via RedisClient
      elsif defined?(Redis::Client)
        MethodProfiler.patch(
          Redis::Client,
          %i[call call_pipeline],
          :redis,
          instrument: config[:instrument],
        )
      end

      if defined?(PG::Connection)
        MethodProfiler.patch(
          PG::Connection,
          %i[exec async_exec exec_prepared exec_params send_query_prepared query],
          :sql,
          instrument: config[:instrument],
        )
      end

      if defined?(Mysql2::Client)
        MethodProfiler.patch(Mysql2::Client, [:query], :sql, instrument: config[:instrument])
        MethodProfiler.patch(Mysql2::Statement, [:execute], :sql, instrument: config[:instrument])
        MethodProfiler.patch(Mysql2::Result, [:each], :sql, instrument: config[:instrument])
      end

      if defined?(Dalli::Client)
        MethodProfiler.patch(
          Dalli::Client,
          %i[delete fetch get add set],
          :memcache,
          instrument: config[:instrument],
        )
      end
    end
  end

  def call(env)
    queue_time = measure_queue_time(env)

    MethodProfiler.start
    result = @app.call(env)
    info = MethodProfiler.stop

    result
  ensure
    status = (result && result[0]) || -1
    obj = {
      type: "web",
      timings: info,
      queue_time: queue_time,
      status: status,
      default_labels: default_labels(env, result),
    }
    labels = custom_labels(env)
    obj = obj.merge(custom_labels: labels) if labels

    @client.send_json(obj)
  end

  def default_labels(env, result)
    controller_instance = env["action_controller.instance"]
    action = controller = nil
    if controller_instance
      action = controller_instance.action_name
      controller = controller_instance.controller_path
    elsif (cors = env["rack.cors"]) && cors.respond_to?(:preflight?) && cors.preflight?
      # if the Rack CORS Middleware identifies the request as a preflight request,
      # the stack doesn't get to the point where controllers/actions are defined
      action = "preflight"
      controller = "preflight"
    end

    { action: action || "other", controller: controller || "other" }
  end

  # allows subclasses to add custom labels based on env
  def custom_labels(env)
    nil
  end

  private

  # measures the queue time (= time between receiving the request in downstream
  # load balancer and starting request in ruby process)
  # The headers this reads are client-supplied, and this runs before the application is
  # even called, so nothing here may raise: a single header would otherwise deny the
  # request. Values that cannot be a real queue time are dropped rather than recorded,
  # since a bogus one corrupts the metric's sum and quantiles for the life of the process.
  MAX_QUEUE_TIME = 3600

  def measure_queue_time(env)
    start_time = queue_start(env)

    return if start_time.nil?

    queue_time = request_start.to_f - start_time.to_f

    return if queue_time.negative? || queue_time > MAX_QUEUE_TIME

    queue_time
  rescue StandardError
    nil
  end

  # need to use CLOCK_REALTIME, as nginx/apache write this also out as the unix timestamp
  def request_start
    Process.clock_gettime(Process::CLOCK_REALTIME)
  end

  # determine queue start from well-known trace headers
  def queue_start(env)
    # get the content of the x-queue-start or x-request-start header
    value = env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"]
    if !value.nil? && value != ""
      # nginx returns time as milliseconds with 3 decimal places
      # apache returns time as microseconds without decimal places
      # this method takes care to convert both into a proper second + fractions timestamp
      # Two proxies each adding the header arrive joined by a comma; the first one is the
      # outermost, so it is the queue time we want.
      digits = value.to_s.split(",").first.to_s.strip.sub(/\At=/, "").delete(".")

      # Anything that is not a plain timestamp is a header we cannot read, not a queue
      # time of 1.79 billion seconds. The upper bound leaves room for nanoseconds.
      return nil if !digits.match?(/\A\d{10,19}\z/)

      return "#{digits[0, 10]}.#{digits[10, 6]}".to_f
    end

    # get the content of the x-amzn-trace-id header
    # see also: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-request-tracing.html
    # Indexed access, not fetch: a Root without a dash used to raise IndexError, which
    # &. does not guard against since it only handles nil.
    value = env["HTTP_X_AMZN_TRACE_ID"]
    return nil if value.nil?

    root = value.split("Root=")[1]

    root&.split("-")&.[](1)&.to_i(16)
  end

  private

  module RedisInstrumenter
    MethodProfiler.define_methods_on_module(self, %w[call call_pipelined], "redis")
  end

  def apply_redis_client_middleware!
    RedisClient.register(RedisInstrumenter)
  end
end
