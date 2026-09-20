# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

# collects stats from GoodJob
module PrometheusExporter::Instrumentation
  class GoodJob < PeriodicStats
    # include_totals: false turns off the three counts that scan the whole table --
    # finished, succeeded and discarded. GoodJob's cleanup is opt-in, so on a retained
    # table those are multi-million row scans every cycle, holding a pooled connection
    # while request threads wait for one. On by default, so no metric disappears on
    # upgrade.
    def self.start(client: nil, frequency: 30, include_totals: true)
      good_job_collector = new(include_totals: include_totals)
      client ||= PrometheusExporter::Client.default

      worker_loop { client.send_json(good_job_collector.collect) }

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    def initialize(include_totals: true)
      @include_totals = include_totals
    end

    def collect
      metric = {
        type: "good_job",
        scheduled: ::GoodJob::Job.scheduled.size,
        retried: ::GoodJob::Job.retried.size,
        queued: ::GoodJob::Job.queued.size,
        running: ::GoodJob::Job.running.size,
      }

      if @include_totals
        metric[:finished] = ::GoodJob::Job.finished.size
        metric[:succeeded] = ::GoodJob::Job.succeeded.size
        metric[:discarded] = ::GoodJob::Job.discarded.size
      end

      metric
    end
  end
end
