# frozen_string_literal: true

module PrometheusExporter::Server
  class DelayedJobCollector < TypeCollector
    def initialize
      @delayed_jobs_total = nil
      @delayed_job_duration_seconds = nil
      @delayed_job_latency_seconds_total = nil
      @delayed_jobs_total = nil
      @delayed_failed_jobs_total = nil
      @delayed_jobs_max_attempts_reached_total = nil
      @delayed_job_duration_seconds_summary = nil
      @delayed_job_attempts_summary = nil
      @delayed_jobs_enqueued = nil
      @delayed_jobs_pending = nil
    end

    def type
      "delayed_job"
    end

    def collect(obj)
      # String keys throughout: Symbol defaults merged with String custom labels used to
      # juxtapose both, emitting the same label name twice and making Prometheus reject
      # the entire scrape.
      custom_labels = labels_hash(obj["custom_labels"])
      gauge_labels = { "queue_name" => obj["queue_name"] }.merge(custom_labels)
      counter_labels = gauge_labels.merge("job_name" => obj["name"])

      ensure_delayed_job_metrics

      # The queue gauges below are keyed on gauge_labels alone and are never reset, so a
      # capped payload must not skip them: their last value would be served forever while
      # the queue kept growing.
      capped = series_capped?(@delayed_jobs_total, counter_labels)
      drop_series(counter_labels) if capped

      if !capped
        @delayed_job_duration_seconds.observe(obj["duration"], counter_labels) if obj["duration"]
        @delayed_job_latency_seconds_total.observe(obj["latency"], counter_labels) if obj["latency"]
        @delayed_jobs_total.observe(1, counter_labels)
        @delayed_failed_jobs_total.observe(1, counter_labels) if !obj["success"]
      end
      attempts = obj["attempts"]
      max_attempts = obj["max_attempts"]
      if !capped && attempts && max_attempts && attempts >= max_attempts
        @delayed_jobs_max_attempts_reached_total.observe(1, counter_labels)
      end
      if obj["duration"]
        @delayed_job_duration_seconds_summary.observe(obj["duration"], counter_labels)
      end
      if !capped && obj["duration"]
        status = obj["success"] ? "success" : "failed"
        @delayed_job_duration_seconds_summary.observe(
          obj["duration"],
          counter_labels.merge("status" => status),
        )
      end
      @delayed_job_attempts_summary.observe(attempts, counter_labels) if obj["success"] && attempts
      # Gauge#observe(nil) deletes the series rather than zeroing it, so a payload that
      # simply omits the key would silently erase the queue from the exposition.
      @delayed_jobs_enqueued.observe(obj["enqueued"], gauge_labels) if obj["enqueued"]
      @delayed_jobs_pending.observe(obj["pending"], gauge_labels) if obj["pending"]
    end

    def metrics
      if @delayed_jobs_total
        [
          @delayed_job_duration_seconds,
          @delayed_job_latency_seconds_total,
          @delayed_jobs_total,
          @delayed_failed_jobs_total,
          @delayed_jobs_max_attempts_reached_total,
          @delayed_job_duration_seconds_summary,
          @delayed_job_attempts_summary,
          @delayed_jobs_enqueued,
          @delayed_jobs_pending,
        ]
      else
        []
      end
    end

    protected

    def ensure_delayed_job_metrics
      if !@delayed_jobs_total
        @delayed_job_duration_seconds =
          PrometheusExporter::Metric::Counter.new(
            "delayed_job_duration_seconds",
            "Total time spent in delayed jobs.",
          )

        @delayed_job_latency_seconds_total =
          PrometheusExporter::Metric::Counter.new(
            "delayed_job_latency_seconds_total",
            "Total delayed jobs latency.",
          )

        @delayed_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "delayed_jobs_total",
            "Total number of delayed jobs executed.",
          )

        @delayed_jobs_enqueued =
          PrometheusExporter::Metric::Gauge.new(
            "delayed_jobs_enqueued",
            "Number of enqueued delayed jobs.",
          )

        @delayed_jobs_pending =
          PrometheusExporter::Metric::Gauge.new(
            "delayed_jobs_pending",
            "Number of pending delayed jobs.",
          )

        @delayed_failed_jobs_total =
          PrometheusExporter::Metric::Counter.new(
            "delayed_failed_jobs_total",
            "Total number failed delayed jobs executed.",
          )

        @delayed_jobs_max_attempts_reached_total =
          PrometheusExporter::Metric::Counter.new(
            "delayed_jobs_max_attempts_reached_total",
            "Total number of delayed jobs that reached max attempts.",
          )

        @delayed_job_duration_seconds_summary =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "delayed_job_duration_seconds_summary",
            "Summary of the time it takes jobs to execute.",
          )

        @delayed_job_attempts_summary =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "delayed_job_attempts_summary",
            "Summary of the amount of attempts it takes delayed jobs to succeed.",
          )
      end
    end
  end
end
