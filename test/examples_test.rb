# frozen_string_literal: true

require_relative "test_helper"
require "prometheus_exporter/server"

# Nothing loaded examples/ before, so the shipped custom collector inherited from a
# constant that exists nowhere and the README's own instructions raised NameError.
class PrometheusExamplesTest < Minitest::Test
  EXAMPLES = Dir[File.expand_path("../examples/*.rb", __dir__)]

  # Minitest interleaves suites and default_prefix is process-wide, so without this the
  # assertion below passes on "ruby_thing1 122" and proves nothing about the name.
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
    PrometheusExporter::Metric::Base.default_labels = {}
  end

  def test_there_is_at_least_one_example_to_check
    refute_empty(EXAMPLES)
  end

  def test_every_example_loads
    EXAMPLES.each { |path| require path }
  end

  def test_the_custom_collector_example_implements_the_collector_contract
    require File.expand_path("../examples/custom_collector.rb", __dir__)
    collector = MyCustomCollector.new

    # The server hands over the raw chunk, exactly as WebServer#handle_metrics does.
    collector.process({ "thing1" => 122 }.to_json)

    assert_includes(collector.prometheus_metrics_text.lines, "thing1 122\n")
  end

  def test_a_web_server_refuses_half_a_tls_pair
    assert_raises(ArgumentError) do
      PrometheusExporter::Server::WebServer.new(port: 0, tls_cert_file: "cert.pem")
    end

    assert_raises(ArgumentError) do
      PrometheusExporter::Server::WebServer.new(port: 0, tls_key_file: "key.pem")
    end
  end

  def test_the_custom_type_collector_fixture_implements_the_type_collector_contract
    require File.expand_path("custom_type_collector.rb", __dir__)
    collector = CustomTypeCollector.new

    assert_equal("custom1", collector.type)

    collector.collect("type" => "custom1", "value" => 1)

    assert_equal([{ "type" => "custom1", "value" => 1 }], collector.collected)
    assert_empty(collector.metrics)
  end
end
