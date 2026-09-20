# frozen_string_literal: true

class CustomTypeCollector < PrometheusExporter::Server::TypeCollector
  def type
    "custom1"
  end

  # collect, not observe: the TypeCollector interface is type/collect/metrics, and a
  # collector implementing observe receives nothing, silently.
  def collect(obj)
    @collected ||= []
    @collected << obj
  end

  attr_reader :collected

  def metrics
    []
  end
end
