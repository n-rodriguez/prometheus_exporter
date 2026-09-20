# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"

# A type collector is fed straight from an unauthenticated socket, so every one of them has
# to survive a payload missing a key, carrying a null where a value is expected, or naming a
# custom label that collides with one the collector sets itself. None of that was covered.
class DegradedPayloadTest < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
  end

  def render(collector)
    collector.metrics.map(&:metric_text).join("\n")
  end

  def test_delayed_job_does_not_emit_a_duplicate_label_name
    collector = PrometheusExporter::Server::DelayedJobCollector.new
    collector.collect(
      "type" => "delayed_job",
      "name" => "J",
      "queue_name" => "default",
      "custom_labels" => {
        "queue_name" => "EVIL",
      },
      "duration" => 1.0,
      "latency" => 1.0,
      "attempts" => 1,
      "max_attempts" => 5,
      "success" => true,
      "enqueued" => 1,
      "pending" => 1,
    )

    line = render(collector).lines.grep(/\Adelayed_jobs_total/).first

    assert_equal(1, line.scan(/queue_name=/).length)
  end

  def test_sidekiq_does_not_emit_a_duplicate_label_name
    collector = PrometheusExporter::Server::SidekiqCollector.new
    collector.collect(
      "type" => "sidekiq",
      "name" => "J",
      "queue" => "default",
      "custom_labels" => {
        "queue" => "EVIL",
      },
      "duration" => 1.0,
      "success" => true,
    )

    line = render(collector).lines.grep(/\Asidekiq_jobs_total/).first

    assert_equal(1, line.scan(/queue=/).length)
  end

  def test_hutch_does_not_emit_a_duplicate_label_name
    collector = PrometheusExporter::Server::HutchCollector.new
    collector.collect(
      "type" => "hutch",
      "name" => "J",
      "custom_labels" => {
        "job_name" => "EVIL",
      },
      "duration" => 1.0,
      "success" => true,
    )

    line = render(collector).lines.grep(/\Ahutch_jobs_total/).first

    assert_equal(1, line.scan(/job_name=/).length)
  end

  def test_shoryuken_does_not_emit_a_duplicate_label_name
    collector = PrometheusExporter::Server::ShoryukenCollector.new
    collector.collect(
      "type" => "shoryuken",
      "name" => "J",
      "queue" => "default",
      "custom_labels" => {
        "queue_name" => "EVIL",
      },
      "duration" => 1.0,
      "success" => true,
    )

    line = render(collector).lines.grep(/\Ashoryuken_jobs_total/).first

    assert_equal(1, line.scan(/queue_name=/).length)
  end

  def test_no_collector_raises_on_a_payload_missing_every_optional_key
    [
      [PrometheusExporter::Server::WebCollector, "web"],
      [PrometheusExporter::Server::SidekiqQueueCollector, "sidekiq_queue"],
      [PrometheusExporter::Server::SidekiqStatsCollector, "sidekiq_stats"],
      [PrometheusExporter::Server::SidekiqProcessCollector, "sidekiq_process"],
      [PrometheusExporter::Server::DelayedJobCollector, "delayed_job"],
      [PrometheusExporter::Server::HutchCollector, "hutch"],
      [PrometheusExporter::Server::ShoryukenCollector, "shoryuken"],
      [PrometheusExporter::Server::ActiveRecordCollector, "active_record"],
      [PrometheusExporter::Server::GoodJobCollector, "good_job"],
      [PrometheusExporter::Server::ResqueCollector, "resque"],
      [PrometheusExporter::Server::UnicornCollector, "unicorn"],
      [PrometheusExporter::Server::PumaCollector, "puma"],
      [PrometheusExporter::Server::ProcessCollector, "process"],
    ].each do |klass, type|
      collector = klass.new

      collector.collect("type" => type)
      render(collector)
    end
  end

  def test_no_collector_raises_on_a_payload_whose_values_are_null
    [
      [PrometheusExporter::Server::WebCollector, "web"],
      [PrometheusExporter::Server::SidekiqQueueCollector, "sidekiq_queue"],
      [PrometheusExporter::Server::SidekiqStatsCollector, "sidekiq_stats"],
      [PrometheusExporter::Server::GoodJobCollector, "good_job"],
      [PrometheusExporter::Server::ResqueCollector, "resque"],
      [PrometheusExporter::Server::UnicornCollector, "unicorn"],
      [PrometheusExporter::Server::PumaCollector, "puma"],
      [PrometheusExporter::Server::ProcessCollector, "process"],
    ].each do |klass, type|
      collector = klass.new

      collector.collect(
        "type" => type,
        "custom_labels" => nil,
        "metric_labels" => nil,
        "default_labels" => nil,
        "stats" => nil,
        "queues" => nil,
      )
      render(collector)
    end
  end

  def test_sidekiq_stats_keeps_custom_labels
    collector = PrometheusExporter::Server::SidekiqStatsCollector.new
    collector.collect(
      "type" => "sidekiq_stats",
      "stats" => {
        "enqueued" => 10,
      },
      "custom_labels" => {
        "cluster" => "a",
      },
    )
    collector.collect(
      "type" => "sidekiq_stats",
      "stats" => {
        "enqueued" => 99,
      },
      "custom_labels" => {
        "cluster" => "b",
      },
    )

    lines = render(collector).lines.grep(/\Asidekiq_stats_enqueued/).map(&:strip).sort

    assert_equal(
      ['sidekiq_stats_enqueued{cluster="a"} 10', 'sidekiq_stats_enqueued{cluster="b"} 99'],
      lines,
    )
  end

  def test_unicorn_keeps_one_series_per_master
    collector = PrometheusExporter::Server::UnicornCollector.new
    collector.collect("type" => "unicorn", "pid" => 1, "hostname" => "h1", "workers" => 4)
    collector.collect("type" => "unicorn", "pid" => 2, "hostname" => "h2", "workers" => 8)

    lines = render(collector).lines.grep(/\Aunicorn_workers/).map(&:strip).sort

    assert_equal(2, lines.length)
  end

  def test_process_keeps_one_series_per_metric_label_set
    collector = PrometheusExporter::Server::ProcessCollector.new
    collector.collect(
      "type" => "process",
      "pid" => 1,
      "hostname" => "h1",
      "metric_labels" => {
        "type" => "web",
      },
      "heap_live_slots" => 10,
    )
    collector.collect(
      "type" => "process",
      "pid" => 1,
      "hostname" => "h1",
      "metric_labels" => {
        "type" => "worker",
      },
      "heap_live_slots" => 20,
    )

    lines = render(collector).lines.grep(/heap_live_slots/).map(&:strip).sort

    assert_equal(2, lines.length)
  end

  def test_good_job_treats_a_null_custom_labels_as_empty
    collector = PrometheusExporter::Server::GoodJobCollector.new
    collector.collect("type" => "good_job", "scheduled" => 1, "custom_labels" => nil)
    collector.collect("type" => "good_job", "scheduled" => 2)

    lines = render(collector).lines.grep(/\Agood_job_scheduled/).map(&:strip)

    assert_equal(1, lines.length)
  end

  def test_resque_treats_a_null_custom_labels_as_empty
    collector = PrometheusExporter::Server::ResqueCollector.new
    collector.collect("type" => "resque", "processed_jobs" => 1, "custom_labels" => nil)
    collector.collect("type" => "resque", "processed_jobs" => 2)

    lines = render(collector).lines.grep(/\Aresque_processed_jobs/).map(&:strip)

    assert_equal(1, lines.length)
  end

  def test_good_job_drops_a_series_whose_host_stopped_reporting
    collector = PrometheusExporter::Server::GoodJobCollector.new
    collector.collect("type" => "good_job", "scheduled" => 5, "custom_labels" => { "host" => "a" })
    render(collector)

    # Let host a's sample age past the container TTL, then have host b report.
    ttl = PrometheusExporter::Server::GoodJobCollector::MAX_METRIC_AGE
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lines = nil
    Process.stub(:clock_gettime, now + ttl + 1) do
      collector.collect(
        "type" => "good_job",
        "scheduled" => 7,
        "custom_labels" => {
          "host" => "b",
        },
      )
      lines = render(collector).lines.grep(/\Agood_job_scheduled/).map(&:strip)
    end

    assert_equal(['good_job_scheduled{host="b"} 7'], lines)
  end

  def test_delayed_job_keeps_a_gauge_series_when_a_value_is_missing
    collector = PrometheusExporter::Server::DelayedJobCollector.new
    base = {
      "type" => "delayed_job",
      "name" => "J",
      "queue_name" => "default",
      "duration" => 1.0,
      "latency" => 1.0,
      "attempts" => 1,
      "max_attempts" => 5,
      "success" => true,
    }

    collector.collect(base.merge("enqueued" => 4, "pending" => 2))

    assert_match(/delayed_jobs_enqueued\{queue_name="default"\} 4/, render(collector))

    collector.collect(base)

    assert_match(/delayed_jobs_enqueued\{queue_name="default"\} 4/, render(collector))
  end

  def test_puma_exports_busy_threads_without_puma_loaded
    collector = PrometheusExporter::Server::PumaCollector.new
    collector.collect("type" => "puma", "pid" => 1, "hostname" => "h1", "busy_threads" => 3)

    assert_match(/puma_busy_threads/, render(collector))
  end

  def test_puma_collector_declares_the_shared_max_metric_age_constant
    assert(PrometheusExporter::Server::PumaCollector.const_defined?(:MAX_METRIC_AGE))
  end

  def test_process_collector_prefixes_its_metric_names
    collector = PrometheusExporter::Server::ProcessCollector.new
    collector.collect("type" => "process", "pid" => 1, "hostname" => "h1", "rss" => 10)

    text = render(collector)

    assert_match(/\Aprocess_rss/, text)
  end

  def test_a_collector_caps_the_number_of_series_it_keeps
    collector = PrometheusExporter::Server::WebCollector.new
    cap = PrometheusExporter::Server::TypeCollector::MAX_SERIES

    (cap + 50).times do |i|
      collector.collect(
        "type" => "web",
        "status" => 200,
        "timings" => nil,
        "default_labels" => {
          "controller" => "c#{i}",
        },
      )
    end

    lines = render(collector).lines.grep(/\Ahttp_requests_total/)

    assert_operator(lines.length, :<=, cap)
  end

  def test_a_capped_delayed_job_payload_still_updates_the_queue_gauges
    collector = PrometheusExporter::Server::DelayedJobCollector.new
    cap = PrometheusExporter::Server::TypeCollector::MAX_SERIES
    base = {
      "type" => "delayed_job",
      "queue_name" => "default",
      "duration" => 1.0,
      "latency" => 1.0,
      "attempts" => 1,
      "max_attempts" => 5,
      "success" => true,
    }

    (cap + 5).times { |i| collector.collect(base.merge("name" => "J#{i}", "enqueued" => i)) }

    enqueued = render(collector).lines.grep(/\Adelayed_jobs_enqueued/).first

    assert_match(/delayed_jobs_enqueued\{queue_name="default"\} #{cap + 4}/, enqueued)
  end

  def test_a_dead_sidekiq_job_has_its_own_cap
    collector = PrometheusExporter::Server::SidekiqCollector.new
    cap = PrometheusExporter::Server::TypeCollector::MAX_SERIES

    (cap + 5).times do |i|
      collector.collect("type" => "sidekiq", "name" => "J#{i}", "queue" => "q", "duration" => 1.0)
    end
    collector.collect("type" => "sidekiq", "name" => "dead", "queue" => "q", "dead" => true)

    assert_match(/sidekiq_dead_jobs_total/, render(collector))
  end

  def test_collectors_survive_a_labels_field_of_the_wrong_type
    [
      [PrometheusExporter::Server::WebCollector, "web"],
      [PrometheusExporter::Server::SidekiqCollector, "sidekiq"],
      [PrometheusExporter::Server::HutchCollector, "hutch"],
      [PrometheusExporter::Server::ShoryukenCollector, "shoryuken"],
      [PrometheusExporter::Server::DelayedJobCollector, "delayed_job"],
    ].each do |klass, type|
      collector = klass.new

      collector.collect(
        "type" => type,
        "name" => "J",
        "status" => 200,
        "custom_labels" => "not a hash",
        "default_labels" => "not a hash either",
      )
      render(collector)
    end
  end

  def test_a_unicorn_payload_without_identity_keys_does_not_wipe_the_container
    collector = PrometheusExporter::Server::UnicornCollector.new
    collector.collect("type" => "unicorn", "workers" => 4)
    collector.collect("type" => "unicorn", "workers" => 4)

    assert_equal(2, collector.instance_variable_get(:@unicorn_metrics).length)
  end

  def test_puma_keeps_the_previous_constant_name_working
    assert_equal(
      PrometheusExporter::Server::PumaCollector::MAX_METRIC_AGE,
      PrometheusExporter::Server::PumaCollector::MAX_PUMA_METRIC_AGE,
    )
  end
end
