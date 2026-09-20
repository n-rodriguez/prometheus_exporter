# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/instrumentation/periodic_stats"

# PeriodicStats is the parent of eight instrumentations and had no test of its own.
class PrometheusPeriodicStatsTest < Minitest::Test
  class Probe < PrometheusExporter::Instrumentation::PeriodicStats
  end

  class RaisingLogger
    def error(*)
      raise "the logger is broken too"
    end

    def warn(*)
      raise "the logger is broken too"
    end
  end

  class FakeClient
    attr_reader :logger

    def initialize(logger)
      @logger = logger
    end
  end

  def teardown
    Probe.stop
  end

  def test_it_refuses_a_frequency_that_is_not_a_number
    Probe.worker_loop { nil }

    assert_raises(ArgumentError) { Probe.start(frequency: "often", client: client) }
  end

  def test_it_refuses_a_negative_frequency
    Probe.worker_loop { nil }

    assert_raises(ArgumentError) { Probe.start(frequency: -1, client: client) }
  end

  def test_it_refuses_an_unknown_keyword
    Probe.worker_loop { nil }

    assert_raises(ArgumentError) { Probe.start(frequency: 0.01, client: client, lables: {}) }
  end

  def test_it_refuses_to_start_without_a_worker_loop
    Probe.worker_loop(&nil) if Probe.respond_to?(:worker_loop)
    Probe.instance_variable_set(:@worker_loop, nil)

    assert_raises(ArgumentError) { Probe.start(frequency: 0.01, client: client) }
  end

  def test_the_loop_survives_a_worker_error_whose_logger_also_raises
    calls = 0
    Probe.worker_loop do
      calls += 1
      raise "worker loop is broken"
    end

    Probe.start(frequency: 0.001, client: FakeClient.new(RaisingLogger.new))

    # The thread has to still be running after the first failure: a logger raising inside
    # the rescue used to kill it, stopping collection for good.
    TestHelper.wait_for(2) { calls > 1 }

    assert(Probe.started?)
    assert_operator(calls, :>, 1)
  end

  def test_stop_does_not_hang_on_a_worker_loop_blocked_on_io
    started = Queue.new
    reader, writer = IO.pipe
    Probe.worker_loop do
      started << true
      # wakeup interrupts a sleep, but not a blocking read: this is the Redis connection
      # gone black-holed that used to freeze application shutdown, and boot with it.
      reader.read(1)
    end

    Probe.start(frequency: 0.001, client: client)
    started.pop

    stopped_within =
      begin
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Probe.stop
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
      end

    refute(Probe.started?)
    assert_operator(
      stopped_within,
      :<,
      PrometheusExporter::Instrumentation::PeriodicStats::STOP_TIMEOUT + 2,
    )
  ensure
    reader&.close
    writer&.close
  end

  def test_it_can_warn_about_a_thread_that_did_not_survive_a_fork
    logs = StringIO.new
    warning_client = FakeClient.new(Logger.new(logs))
    Probe.worker_loop { nil }
    Probe.start(frequency: 10, client: warning_client)
    Probe.instance_variable_set(:@started_in_pid, Process.pid - 1)

    Probe.warn_if_dead_after_fork(warning_client)

    assert_includes(logs.string, "did not survive fork")
  end

  def test_start_itself_does_not_warn_about_the_fork_it_is_recovering_from
    logs = StringIO.new
    warning_client = FakeClient.new(Logger.new(logs))
    Probe.worker_loop { nil }
    Probe.start(frequency: 10, client: warning_client)
    Probe.instance_variable_set(:@started_in_pid, Process.pid - 1)

    # This is the README's own after_fork pattern: restarting in the child is correct,
    # and must not log a warning telling the user to do what they just did.
    Probe.start(frequency: 10, client: warning_client)

    refute_includes(logs.string, "did not survive fork")
  end

  def test_it_knows_its_thread_did_not_survive_a_fork
    Probe.worker_loop { nil }
    Probe.start(frequency: 10, client: client)

    refute(Probe.dead_after_fork?)

    Probe.instance_variable_set(:@started_in_pid, Process.pid - 1)

    assert(Probe.dead_after_fork?)
  end

  private

  def client
    FakeClient.new(Logger.new(IO::NULL))
  end
end
