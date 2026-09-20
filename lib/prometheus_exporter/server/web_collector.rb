# frozen_string_literal: true

module PrometheusExporter::Server
  class WebCollector < TypeCollector
    def initialize
      @metrics = {}
      @http_requests_total = nil
      @http_request_duration_seconds = nil
      @http_request_redis_duration_seconds = nil
      @http_request_sql_duration_seconds = nil
      @http_request_queue_duration_seconds = nil
      @http_request_memcache_duration_seconds = nil
    end

    def type
      "web"
    end

    def collect(obj)
      ensure_metrics
      observe(obj)
    end

    def metrics
      @metrics.values + PrometheusExporter::Server::TypeCollector.dropped_series_metrics
    end

    protected

    def ensure_metrics
      unless @http_requests_total
        @metrics["http_requests_total"] = @http_requests_total =
          PrometheusExporter::Metric::Counter.new(
            "http_requests_total",
            "Total HTTP requests from web app.",
          )

        @metrics["http_request_duration_seconds"] = @http_request_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_duration_seconds",
            "Time spent in HTTP reqs in seconds.",
          )

        @metrics["http_request_redis_duration_seconds"] = @http_request_redis_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_redis_duration_seconds",
            "Time spent in HTTP reqs in Redis, in seconds.",
          )

        @metrics["http_request_sql_duration_seconds"] = @http_request_sql_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_sql_duration_seconds",
            "Time spent in HTTP reqs in SQL in seconds.",
          )

        @metrics[
          "http_request_memcache_duration_seconds"
        ] = @http_request_memcache_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_memcache_duration_seconds",
            "Time spent in HTTP reqs in Memcache in seconds.",
          )

        @metrics["http_request_queue_duration_seconds"] = @http_request_queue_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_queue_duration_seconds",
            "Time spent queueing the request in load balancer in seconds.",
          )
      end
    end

    def observe(obj)
      # Both keys are optional on the wire, and a JSON null yields nil rather than {}.
      labels = labels_hash(obj["default_labels"]).merge(labels_hash(obj["custom_labels"]))

      status_labels = labels.merge("status" => obj["status"])
      return drop_series(status_labels) if series_capped?(@http_requests_total, status_labels)

      @http_requests_total.observe(1, status_labels)

      if timings = obj["timings"]
        @http_request_duration_seconds.observe(timings["total_duration"], labels)
        if redis = timings["redis"]
          @http_request_redis_duration_seconds.observe(redis["duration"], labels)
        end
        if sql = timings["sql"]
          @http_request_sql_duration_seconds.observe(sql["duration"], labels)
        end
        if memcache = timings["memcache"]
          @http_request_memcache_duration_seconds.observe(memcache["duration"], labels)
        end
      end
      if queue_time = obj["queue_time"]
        @http_request_queue_duration_seconds.observe(queue_time, labels)
      end
    end
  end
end
