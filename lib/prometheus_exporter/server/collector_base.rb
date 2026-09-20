# frozen_string_literal: true

module PrometheusExporter::Server
  # minimal interface to implement a customer collector
  class CollectorBase
    # Both stubs raise, like TypeCollector does. Returning nil silently swallowed every
    # payload a subclass forgot to handle, leaving /metrics empty with nothing logged.

    # called each time a string is delivered from the web
    def process(str)
      raise "must be implemented"
    end

    # a string denoting the metrics
    #
    # Takes no argument: the server has always called this with none, so the documented
    # signature made the shipped base class raise ArgumentError on the first scrape.
    def prometheus_metrics_text
      raise "must be implemented"
    end
  end
end
