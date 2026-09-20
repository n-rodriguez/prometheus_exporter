# frozen_string_literal: true

require "logger"

module PrometheusExporter::Server
  class Collector < CollectorBase
    # Caps the size of an array option arriving from the network. Rendering sorts and
    # walks these on every scrape, under the global mutex.
    MAX_OPTS_SIZE = 64
    ARRAY_OPTS = %i[quantiles buckets].freeze

    attr_reader :logger

    def initialize(json_serializer: nil, logger: Logger.new(STDERR))
      @logger = logger
      @process_metrics = []
      @metrics = {}
      @mutex = Mutex.new
      @collectors = {}
      @json_serializer = PrometheusExporter.detect_json_serializer(json_serializer)
      register_collector(WebCollector.new)
      register_collector(ProcessCollector.new)
      register_collector(SidekiqCollector.new)
      register_collector(SidekiqQueueCollector.new)
      register_collector(SidekiqProcessCollector.new)
      register_collector(SidekiqStatsCollector.new)
      register_collector(DelayedJobCollector.new)
      register_collector(PumaCollector.new)
      register_collector(HutchCollector.new)
      register_collector(UnicornCollector.new)
      register_collector(ActiveRecordCollector.new)
      register_collector(ShoryukenCollector.new)
      register_collector(ResqueCollector.new)
      register_collector(GoodJobCollector.new)
    end

    def register_collector(collector)
      @collectors[collector.type] = collector
    end

    # Metrics are indexed under the name as it will be rendered, so two payloads whose
    # names only differ by characters the sanitizer rewrites land on one metric instead of
    # emitting two identical HELP/TYPE blocks, which Prometheus rejects the scrape over.
    def metric_key(name)
      PrometheusExporter::Metric::Base.sanitize_metric_name(name)
    end

    def process(str)
      process_hash(@json_serializer.parse(str))
    end

    def process_hash(obj)
      @mutex.synchronize do
        if collector = @collectors[obj["type"]]
          collector.collect(obj)
        else
          # The empty-name guard runs before metric_key, which would turn nil or "" into a
          # valid identifier and silently fold those payloads onto an existing metric.
          raw_name = obj["name"]
          if raw_name.nil? || raw_name.to_s.empty?
            register_metric_unsafe(obj)
            next
          end

          metric = @metrics[metric_key(raw_name)]
          metric = register_metric_unsafe(obj) if !metric

          next unless metric

          keys = obj["keys"] || {}
          keys = obj["custom_labels"].merge(keys) if obj["custom_labels"]

          case obj["prometheus_exporter_action"]
          when "increment"
            metric.increment(keys, obj["value"])
          when "decrement"
            metric.decrement(keys, obj["value"])
          else
            metric.observe(obj["value"], keys)
          end
        end
      end
    end

    def prometheus_metrics_text
      @mutex.synchronize do
        (@metrics.values + @collectors.values.map(&:metrics).flatten).map(
          &:to_prometheus_text
        ).join("\n")
      end
    end

    def register_metric(metric)
      @mutex.synchronize { @metrics[metric_key(metric.name)] = metric }
    end

    protected

    def register_metric_unsafe(obj)
      raw_name = obj["name"]
      help = obj["help"]
      opts = validate_opts(symbolize_keys(obj["opts"] || {}))

      if raw_name.nil? || raw_name.to_s.empty?
        logger.warn "failed to register metric due to empty name #{obj}"
        return
      end

      name = metric_key(raw_name)
      metric = build_metric(obj["type"], name, help, opts)

      if metric
        @metrics[name] = metric
      else
        # Returns nil, not the value of logger.warn: the caller tests the result for
        # truthiness before observing on it.
        logger.warn "failed to register metric #{obj}"
        nil
      end
    end

    # A payload must never take an exception out of here: it would propagate to the web
    # server, which abandons the rest of the sender's chunked batch. Gauge refuses a
    # _total suffix, and the strict name validators raise ArgumentError subclasses.
    def build_metric(type, name, help, opts)
      case type
      when "gauge"
        PrometheusExporter::Metric::Gauge.new(name, help)
      when "counter"
        PrometheusExporter::Metric::Counter.new(name, help)
      when "summary"
        PrometheusExporter::Metric::Summary.new(name, help, opts)
      when "histogram"
        PrometheusExporter::Metric::Histogram.new(name, help, opts)
      end
    rescue ArgumentError => e
      logger.warn "failed to register metric #{name}: #{e.message}"
      nil
    end

    # Quantiles and buckets come straight off the wire and are walked on every scrape.
    # An option of the wrong type used to detonate at render time, taking /metrics down
    # for every collector; an oversized one is a cheap way to make each scrape expensive.
    def validate_opts(opts)
      ARRAY_OPTS.each do |key|
        value = opts[key]
        next if value.nil?

        if !value.is_a?(Array)
          logger.warn "ignoring #{key}: expected an array of numbers, got #{value.class}"
          opts.delete(key)
          next
        end

        # Size before contents: this runs under the global mutex, so walking a
        # multi-million entry array to type-check it is itself the denial of service.
        if value.length > MAX_OPTS_SIZE
          logger.warn "ignoring #{key}: #{value.length} entries exceeds the #{MAX_OPTS_SIZE} cap"
          opts.delete(key)
          next
        end

        if value.any? { |entry| !entry.is_a?(Numeric) }
          logger.warn "ignoring #{key}: expected an array of numbers"
          opts.delete(key)
        end
      end
      opts
    end

    def symbolize_keys(hash)
      hash.inject({}) do |memo, k|
        memo[k.first.to_sym] = k.last
        memo
      end
    end
  end
end
