# frozen_string_literal: true

module PrometheusExporter::Server
  class HutchCollector < TypeCollector
    def initialize
      @hutch_jobs_total = nil
      @hutch_job_duration_seconds = nil
      @hutch_jobs_total = nil
      @hutch_failed_jobs_total = nil
    end

    def type
      "hutch"
    end

    def collect(obj)
      # String keys: see DelayedJobCollector#collect.
      default_labels = { "job_name" => obj["name"] }
      labels = default_labels.merge(labels_hash(obj["custom_labels"]))

      ensure_hutch_metrics
      return drop_series(labels) if series_capped?(@hutch_jobs_total, labels)

      @hutch_job_duration_seconds.observe(obj["duration"], labels) if obj["duration"]
      @hutch_jobs_total.observe(1, labels)
      @hutch_failed_jobs_total.observe(1, labels) if !obj["success"]
    end

    def metrics
      if @hutch_jobs_total
        [@hutch_job_duration_seconds, @hutch_jobs_total, @hutch_failed_jobs_total]
      else
        []
      end
    end

    protected

    def ensure_hutch_metrics
      if !@hutch_jobs_total
        @hutch_job_duration_seconds =
          PrometheusExporter::Metric::Counter.new(
            "hutch_job_duration_seconds",
            "Total time spent in hutch jobs.",
          )

        @hutch_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "hutch_jobs_total",
            "Total number of hutch jobs executed.",
          )

        @hutch_failed_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "hutch_failed_jobs_total",
            "Total number failed hutch jobs executed.",
          )
      end
    end
  end
end
