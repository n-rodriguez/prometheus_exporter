# frozen_string_literal: true

# CollectorBase, not BaseCollector: the latter exists nowhere, so running the exporter
# with `--collector examples/custom_collector.rb`, as the README instructs, raised
# NameError before anything started.
class MyCustomCollector < PrometheusExporter::Server::CollectorBase
  def initialize
    @gauge1 = PrometheusExporter::Metric::Gauge.new("thing1", "I am thing 1")
    @gauge2 = PrometheusExporter::Metric::Gauge.new("thing2", "I am thing 2")
    @mutex = Mutex.new
  end

  # The server hands over the raw chunk as a String, not a parsed Hash. Without this
  # parse, String#[]("thing1") simply returned nil, the gauges were never observed, and
  # the scrape showed their initial value forever.
  def process(str)
    obj = JSON.parse(str)

    @mutex.synchronize do
      if thing1 = obj["thing1"]
        @gauge1.observe(thing1)
      end

      if thing2 = obj["thing2"]
        @gauge2.observe(thing2)
      end
    end
  end

  def prometheus_metrics_text
    @mutex.synchronize { "#{@gauge1.to_prometheus_text}\n#{@gauge2.to_prometheus_text}" }
  end
end
