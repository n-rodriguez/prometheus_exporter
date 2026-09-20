# frozen_string_literal: true

require_relative "periodic_stats"
require_relative "../client"

# collects stats from currently running process
module PrometheusExporter::Instrumentation
  class ActiveRecord < PeriodicStats
    ALLOWED_CONFIG_LABELS = %i[database username host port]

    def self.start(client: nil, frequency: 30, custom_labels: {}, config_labels: [])
      client ||= PrometheusExporter::Client.default

      # Not all rails versions support connection pool stats
      unless ::ActiveRecord::Base.connection_pool.respond_to?(:stat)
        client.logger.error(
          "ActiveRecord connection pool stats not supported in your rails version",
        )
        return
      end

      # Non-destructive: map! rewrote the caller's array, and raised FrozenError outright
      # on a frozen literal.
      config_labels = config_labels.map(&:to_sym)
      validate_config_labels(config_labels)

      active_record_collector = new(custom_labels, config_labels)

      worker_loop do
        metrics = active_record_collector.collect
        metrics.each { |metric| client.send_json metric }
      end

      # Explicit: PeriodicStats.start no longer accepts a catch-all, so a keyword this
      # subclass owns must not be forwarded to it.
      super(frequency: frequency, client: client)
    end

    def self.validate_config_labels(config_labels)
      return if config_labels.size == 0
      if (config_labels - ALLOWED_CONFIG_LABELS).size > 0
        raise "Invalid Config Labels, available options #{ALLOWED_CONFIG_LABELS}"
      end
    end

    def initialize(metric_labels, config_labels)
      @metric_labels = metric_labels
      @config_labels = config_labels
    end

    def collect
      metrics = []
      collect_active_record_pool_stats(metrics)
      metrics
    end

    def pid
      @pid = ::Process.pid
    end

    # The connection handler's own list, not ObjectSpace: sweeping the whole heap every
    # cycle holds the GVL throughout, and returns superseded pools that are unreachable
    # but not yet collected -- two samples carrying the same pool_name in one batch.
    def connection_pools
      handler = ::ActiveRecord::Base.connection_handler

      # connection_pool_list first: all_connection_pools exists only on AR 7.1, where it
      # is already deprecated, and warns -- or raises, under deprecation = :raise -- on
      # every cycle.
      if handler.respond_to?(:connection_pool_list)
        handler.connection_pool_list(:all)
      elsif handler.respond_to?(:all_connection_pools)
        handler.all_connection_pools
      else
        []
      end
      # No rescue: PeriodicStats logs what comes out of the worker loop, and swallowing it
      # here would make the metrics vanish without a trace.
    end

    def collect_active_record_pool_stats(metrics)
      connection_pools.each do |pool|
        next if pool.connections.nil?

        metric = {
          pid: pid,
          type: "active_record",
          hostname: ::PrometheusExporter.hostname,
          metric_labels: labels(pool),
        }
        metric.merge!(pool.stat)
        metrics << metric
      end
    end

    private

    def labels(pool)
      if ::ActiveRecord.version < Gem::Version.new("6.1.0.rc1")
        @metric_labels.merge(pool_name: pool.spec.name).merge(
          pool
            .spec
            .config
            .select { |k, v| @config_labels.include? k }
            .map { |k, v| [k.to_s.dup.prepend("dbconfig_"), v] }
            .to_h,
        )
      else
        @metric_labels.merge(pool_name: pool.db_config.name).merge(
          @config_labels.each_with_object({}) do |l, acc|
            acc["dbconfig_#{l}"] = pool.db_config.public_send(l)
          end,
        )
      end
    end
  end
end
