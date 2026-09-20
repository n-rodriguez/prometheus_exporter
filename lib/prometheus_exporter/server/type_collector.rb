# frozen_string_literal: true

require "prometheus_exporter/server/metrics_container"

module PrometheusExporter::Server
  class TypeCollector
    # Labels of the job and web collectors come entirely from the network, and every
    # distinct value used to create a permanent series -- for a Summary, two buffers of
    # raw floats each. A sender looping over a request id was enough to exhaust memory.
    MAX_SERIES = 1_000

    def type
      raise "must implement type"
    end

    # True when a new label set would push the metric past its series cap. An already
    # known label set always goes through, so existing series keep being updated.
    def series_capped?(metric, labels)
      data = metric.data
      return false if data.nil? || data.key?(labels)

      data.length >= self.class::MAX_SERIES
    end

    # One counter for every type collector, not one each: the exposition carries a single
    # HELP block per metric name, and Collector#prometheus_metrics_text concatenates what
    # each collector returns without deduplicating.
    def self.dropped_series_total
      @dropped_series_total ||=
        PrometheusExporter::Metric::Counter.new(
          "collector_dropped_series_total",
          "Number of series dropped by a type collector after reaching its cap.",
        )
    end

    # Only exported once something has actually been dropped, so an exporter that never
    # hits its cap does not carry the counter in every scrape. Exported by WebCollector,
    # which is always registered, so the block appears exactly once.
    # Process-wide state, so a test that fills a cap has to clear it for the next one.
    def self.reset_dropped_series!
      @dropped_series_total = nil
    end

    def self.dropped_series_metrics
      return [] if @dropped_series_total.nil? || @dropped_series_total.data.empty?

      [@dropped_series_total]
    end

    def drop_series(labels)
      TypeCollector.dropped_series_total.observe(1, "type" => type)
      nil
    end

    # Payload values are untrusted: a key can be absent, null, or of the wrong type
    # entirely, and only the first two were guarded.
    def labels_hash(value)
      return {} if !value.is_a?(Hash)

      value
    end

    def collect(obj)
      raise "must implement collect"
    end

    def metrics
      raise "must implement metrics"
    end
  end
end
