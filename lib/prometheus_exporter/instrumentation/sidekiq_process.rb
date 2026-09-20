# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

module PrometheusExporter::Instrumentation
  class SidekiqProcess < PeriodicStats
    # include_identity: false drops the tag and identity labels. They are unbounded -- a
    # Sidekiq identity is hostname:pid:randomhex, so every restart mints a new one and
    # leaves a dead series behind. On by default, so no label disappears on upgrade.
    def self.start(client: nil, frequency: 30, include_identity: true)
      client ||= PrometheusExporter::Client.default
      sidekiq_process_collector = new(include_identity: include_identity)

      worker_loop { client.send_json(sidekiq_process_collector.collect) }

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    def initialize(include_identity: true)
      @pid = ::Process.pid
      @hostname = Socket.gethostname
      @include_identity = include_identity
    end

    def collect
      { type: "sidekiq_process", process: collect_stats }
    end

    def collect_stats
      process = current_process
      return {} unless process

      {
        busy: process["busy"],
        concurrency: process["concurrency"],
        # identity is hostname:pid:randomhex, so it is unique per process boot: every
        # restart used to leave a dead series behind, for as long as the collector holds
        # them. tag is free-form and just as unbounded. Both are opt-in now.
        labels: {
          labels: process["labels"].sort.join(","),
          queues: process["queues"].sort.join(","),
          quiet: process["quiet"],
          hostname: process["hostname"],
        }.merge(high_cardinality_labels(process)),
      }
    end

    # tag and identity, only when the caller asked for them. Documented as unbounded.
    def high_cardinality_labels(process)
      return {} if !@include_identity

      { tag: process["tag"], identity: process["identity"] }
    end

    def current_process
      ::Sidekiq::ProcessSet.new.find { |sp| sp["hostname"] == @hostname && sp["pid"] == @pid }
    end
  end
end
