# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

require "json"

# collects stats from puma
module PrometheusExporter::Instrumentation
  class Puma < PeriodicStats
    def self.start(client: nil, frequency: 30, labels: {})
      puma_collector = new(labels)
      client ||= PrometheusExporter::Client.default

      worker_loop do
        metric = puma_collector.collect
        client.send_json metric
      end

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    def initialize(metric_labels = {})
      @metric_labels = metric_labels
    end

    def collect
      metric = {
        pid: pid,
        type: "puma",
        hostname: ::PrometheusExporter.hostname,
        metric_labels: @metric_labels,
      }
      collect_puma_stats(metric)
      metric
    end

    def pid
      @pid = ::Process.pid
    end

    def collect_puma_stats(metric)
      stats = JSON.parse(::Puma.stats)

      if stats.key?("workers")
        metric[:phase] = stats["phase"]
        metric[:workers] = stats["workers"]
        metric[:booted_workers] = stats["booted_workers"]
        metric[:old_workers] = stats["old_workers"]

        (stats["worker_status"] || []).each do |worker|
          # A worker freshly forked during a phased restart appears before its first
          # status ping, with last_status nil rather than empty.
          status = worker["last_status"]
          next if status.nil? || status.empty?

          collect_worker_status(metric, status)
        end
      else
        collect_worker_status(metric, stats)
      end
    end

    private

    def collect_worker_status(metric, status)
      # Only keys the Puma version actually reports are accumulated. Adding them blind
      # raised TypeError on an unexpected layout, which PeriodicStats logs once before
      # dropping the whole Puma batch; defaulting them to zero would be worse still, since
      # a thread_pool_capacity of 0 reads as an exhausted pool rather than as a gauge this
      # Puma does not publish.
      {
        request_backlog: "backlog",
        running_threads: "running",
        thread_pool_capacity: "pool_capacity",
        max_threads: "max_threads",
        busy_threads: "busy_threads",
      }.each do |key, stat_name|
        value = status[stat_name]
        next if !value.is_a?(Numeric)

        metric[key] = (metric[key] || 0) + value
      end
    end
  end
end
