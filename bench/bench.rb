# frozen_string_literal: true

# lib/ on the load path: prometheus_exporter/server/type_collector.rb requires by absolute
# path, so from a checkout this file used to die on a LoadError. An installed gem hides it,
# since rubygems activates the spec's lib path.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require_relative "../lib/prometheus_exporter"
require_relative "../lib/prometheus_exporter/client"
require_relative "../lib/prometheus_exporter/server"

# test how long it takes a custom collector to process 10k messages

class Collector
  def initialize(done)
    @i = 0
    @done = done
  end

  def process(message)
    _parsed = JSON.parse(message)
    @i += 1
    @done.call if @i % 10_000 == 0
  end

  def prometheus_metrics_text
  end
end

@start = nil
@client = nil
@runs = 1000

done =
  lambda do
    puts "Elapsed for 10k messages is #{Time.now - @start}"
    if (@runs -= 1) > 0
      @start = Time.now
      10_000.times { @client.send_json(hello: "world") }
    end
  end

collector = Collector.new(done)
server = PrometheusExporter::Server::WebServer.new port: 12_349, collector: collector
server.start
@client = PrometheusExporter::Client.new port: 12_349, max_queue_size: 100_000

@start = Time.now
10_000.times { @client.send_json(hello: "world") }

sleep
