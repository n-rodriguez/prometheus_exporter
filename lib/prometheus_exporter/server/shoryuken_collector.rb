# frozen_string_literal: true

module PrometheusExporter::Server
  class ShoryukenCollector < TypeCollector
    def initialize
      @shoryuken_jobs_total = nil
      @shoryuken_job_duration_seconds = nil
      @shoryuken_jobs_total = nil
      @shoryuken_restarted_jobs_total = nil
      @shoryuken_failed_jobs_total = nil
    end

    def type
      "shoryuken"
    end

    def collect(obj)
      # String keys: see DelayedJobCollector#collect.
      default_labels = { "job_name" => obj["name"], "queue_name" => obj["queue"] }
      labels = default_labels.merge(labels_hash(obj["custom_labels"]))

      ensure_shoryuken_metrics
      return drop_series(labels) if series_capped?(@shoryuken_jobs_total, labels)

      @shoryuken_job_duration_seconds.observe(obj["duration"], labels) if obj["duration"]
      @shoryuken_jobs_total.observe(1, labels)
      @shoryuken_restarted_jobs_total.observe(1, labels) if obj["shutdown"]
      @shoryuken_failed_jobs_total.observe(1, labels) if !obj["success"] && !obj["shutdown"]
    end

    def metrics
      if @shoryuken_jobs_total
        [
          @shoryuken_job_duration_seconds,
          @shoryuken_jobs_total,
          @shoryuken_restarted_jobs_total,
          @shoryuken_failed_jobs_total,
        ]
      else
        []
      end
    end

    protected

    def ensure_shoryuken_metrics
      if !@shoryuken_jobs_total
        @shoryuken_job_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "shoryuken_job_duration_seconds",
            "Total time spent in shoryuken jobs.",
          )

        @shoryuken_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "shoryuken_jobs_total",
            "Total number of shoryuken jobs executed.",
          )

        @shoryuken_restarted_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "shoryuken_restarted_jobs_total",
            "Total number of shoryuken jobs that we restarted because of a shoryuken shutdown.",
          )

        @shoryuken_failed_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "shoryuken_failed_jobs_total",
            "Total number of failed shoryuken jobs.",
          )
      end
    end
  end
end
