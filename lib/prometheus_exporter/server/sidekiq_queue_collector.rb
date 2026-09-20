# frozen_string_literal: true
module PrometheusExporter::Server
  class SidekiqQueueCollector < TypeCollector
    MAX_METRIC_AGE = 60

    SIDEKIQ_QUEUE_GAUGES = {
      "backlog" => "Size of the sidekiq queue.",
      "latency_seconds" => "Latency of the sidekiq queue.",
    }.freeze

    attr_reader :sidekiq_metrics, :gauges

    def initialize
      @sidekiq_metrics = MetricsContainer.new(ttl: MAX_METRIC_AGE)
      @gauges = {}
    end

    def type
      "sidekiq_queue"
    end

    def metrics
      SIDEKIQ_QUEUE_GAUGES.each_key { |name| gauges[name]&.reset! }

      sidekiq_metrics.map do |metric|
        labels = metric.fetch("labels", {})
        SIDEKIQ_QUEUE_GAUGES.map do |name, help|
          if (value = metric[name])
            gauge =
              gauges[name] ||= PrometheusExporter::Metric::Gauge.new("sidekiq_queue_#{name}", help)
            gauge.observe(value, labels)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      # queues, and a queue's labels, are both optional on the wire. Dereferencing them
      # blind raised out of collect, which used to abort the sender's whole batch.
      queues = object["queues"]
      return if !queues.is_a?(Array)

      custom_labels = object["custom_labels"]
      queues.each do |queue|
        next if !queue.is_a?(Hash)

        if custom_labels
          queue["labels"] = labels_hash(queue["labels"]).merge(labels_hash(custom_labels))
        end
        @sidekiq_metrics << queue
      end
    end
  end
end
