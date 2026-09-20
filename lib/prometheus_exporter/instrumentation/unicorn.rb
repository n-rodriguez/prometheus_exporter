# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

begin
  require "raindrops"
rescue LoadError
  # No raindrops available, dont do anything
end

module PrometheusExporter::Instrumentation
  # collects stats from unicorn
  class Unicorn < PeriodicStats
    def self.start(pid_file:, listener_address:, client: nil, frequency: 30)
      unicorn_collector = new(pid_file: pid_file, listener_address: listener_address)
      client ||= PrometheusExporter::Client.default

      worker_loop do
        metric = unicorn_collector.collect
        client.send_json metric
      end

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    def initialize(pid_file:, listener_address:)
      @pid_file = pid_file
      @listener_address = listener_address
      @tcp = listener_address =~ /\A.+:\d+\z/
    end

    def collect
      metric = {}
      metric[:type] = "unicorn"
      collect_unicorn_stats(metric)
      metric
    end

    def collect_unicorn_stats(metric)
      stats = listener_address_stats

      metric[:active_workers] = stats.active
      metric[:request_backlog] = stats.queued
      metric[:workers] = worker_process_count
    end

    private

    def worker_process_count
      return nil unless File.exist?(@pid_file)
      pid = File.read(@pid_file).to_i

      return nil if pid < 1

      # find all processes whose parent is the unicorn master
      # but we're actually only interested in the number of processes (= lines of output)
      result = worker_pgrep(pid)

      # pgrep exits 1 when it matched nothing, which is a genuine zero and must still be
      # reported -- that is the value an alert on "no workers left" fires on. Any other
      # status means the tool itself failed, and a measurement we do not have is better
      # left absent than reported as zero.
      status = $?.exitstatus
      return nil if status != 0 && status != 1

      result.lines.count
    end

    def worker_pgrep(pid)
      `pgrep -P #{pid} -f unicorn -a`
    end

    def listener_address_stats
      if @tcp
        Raindrops::Linux.tcp_listener_stats([@listener_address])[@listener_address]
      else
        Raindrops::Linux.unix_listener_stats([@listener_address])[@listener_address]
      end
    end
  end
end
