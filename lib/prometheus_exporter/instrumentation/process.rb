# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

# collects stats from currently running process
module PrometheusExporter::Instrumentation
  class Process < PeriodicStats
    def self.start(client: nil, type: "ruby", frequency: 30, labels: nil, include_v8: true)
      metric_labels =
        if labels && type
          labels.merge(type: type)
        elsif labels
          labels
        else
          { type: type }
        end

      process_collector = new(metric_labels, include_v8)
      client ||= PrometheusExporter::Client.default

      worker_loop do
        metric = process_collector.collect
        client.send_json metric
      end

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    # include_v8 is positional on purpose: Process.new(type: "web") is a documented call
    # passing a labels hash, and a keyword here would make Ruby read it as keywords.
    def initialize(metric_labels, include_v8 = true)
      @metric_labels = metric_labels
      @include_v8 = include_v8
    end

    def collect
      metric = {}
      metric[:type] = "process"
      metric[:metric_labels] = @metric_labels
      metric[:hostname] = ::PrometheusExporter.hostname
      collect_gc_stats(metric)
      # A full heap sweep plus a heap_stats call per context, every cycle, in a thread
      # holding the GVL: on an application with a large heap this shows up as periodic
      # request latency spikes.
      collect_v8_stats(metric) if @include_v8
      collect_process_stats(metric)
      metric
    end

    def pid
      @pid = ::Process.pid
    end

    def rss
      # Etc.sysconf rather than backticks: forking a possibly multi-gigabyte Ruby process
      # from a background thread can fail under memory pressure, and the 4096 fallback is
      # wrong on arm64 Linux, which uses 16 KiB pages and would under-report RSS fourfold.
      @pagesize ||=
        begin
          require "etc"
          Etc.sysconf(Etc::SC_PAGESIZE)
        rescue StandardError
          4096
        end
      begin
        File.read("/proc/#{pid}/statm").split(" ")[1].to_i * @pagesize
      rescue StandardError
        0
      end
    end

    def collect_process_stats(metric)
      metric[:pid] = pid
      metric[:rss] = rss
    end

    SWEEPING_AND_MARKING = RUBY_VERSION >= "3.3.0"

    def collect_gc_stats(metric)
      stat = GC.stat
      metric[:heap_live_slots] = stat[:heap_live_slots]
      metric[:heap_free_slots] = stat[:heap_free_slots]
      metric[:major_gc_ops_total] = stat[:major_gc_count]
      metric[:minor_gc_ops_total] = stat[:minor_gc_count]
      metric[:allocated_objects_total] = stat[:total_allocated_objects]
      metric[:malloc_increase_bytes_limit] = stat[:malloc_increase_bytes_limit]
      metric[:oldmalloc_increase_bytes_limit] = stat[:oldmalloc_increase_bytes_limit]
      if SWEEPING_AND_MARKING
        metric[:marking_time] = stat[:marking_time]
        metric[:sweeping_time] = stat[:sweeping_time]
      end
    end

    def collect_v8_stats(metric)
      return if !defined?(MiniRacer)

      metric[:v8_heap_count] = metric[:v8_heap_size] = 0
      metric[:v8_heap_size] = metric[:v8_physical_size] = 0
      metric[:v8_used_heap_size] = 0

      ObjectSpace.each_object(MiniRacer::Context) do |context|
        stats = context.heap_stats
        if stats
          metric[:v8_heap_count] += 1
          metric[:v8_heap_size] += stats[:total_heap_size].to_i
          metric[:v8_used_heap_size] += stats[:used_heap_size].to_i
          metric[:v8_physical_size] += stats[:total_physical_size].to_i
        end
      end
    end
  end
end
