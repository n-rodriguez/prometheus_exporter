# frozen_string_literal: true

# custom type collector for prometheus_exporter for handling the metrics sent from
# PrometheusExporter::Instrumentation::Unicorn
module PrometheusExporter::Server
  class UnicornCollector < PrometheusExporter::Server::TypeCollector
    MAX_METRIC_AGE = 60

    UNICORN_GAUGES = {
      workers: "Number of unicorn workers.",
      active_workers: "Number of active unicorn workers",
      request_backlog: "Number of requests waiting to be processed by a unicorn worker.",
    }.freeze

    def initialize
      @unicorn_metrics = MetricsContainer.new(ttl: MAX_METRIC_AGE)
      # Without a filter, a second master's sample never evicted the first one's; without
      # pid and hostname in the labels, both rendered as one series and the older value
      # was silently overwritten.
      # Instrumentation::Unicorn does not send pid or hostname yet, and without them the
      # comparison below would be nil == nil for every pair, wiping the container on each
      # sample. Only evict when at least one identity key is actually present.
      @unicorn_metrics.filter = ->(new_metric, old_metric) do
        next false if new_metric["pid"].nil? && new_metric["hostname"].nil?

        new_metric["pid"] == old_metric["pid"] && new_metric["hostname"] == old_metric["hostname"]
      end
    end

    def type
      "unicorn"
    end

    def metrics
      return [] if @unicorn_metrics.length.zero?

      metrics = {}

      @unicorn_metrics.map do |m|
        labels = {}
        labels["pid"] = m["pid"] if m["pid"]
        labels["hostname"] = m["hostname"] if m["hostname"]
        labels.merge!(m["custom_labels"]) if m["custom_labels"]

        UNICORN_GAUGES.map do |k, help|
          k = k.to_s
          if (v = m[k])
            g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new("unicorn_#{k}", help)
            g.observe(v, labels)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      @unicorn_metrics << obj
    end
  end
end
