# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/instrumentation/method_profiler"

class PrometheusMethodProfilerTest < Minitest::Test
  MP = PrometheusExporter::Instrumentation::MethodProfiler

  def teardown
    MP.clear
  end

  def record_one_call
    (MP.current[:sql] ||= { duration: 0.0, calls: 0 })[:calls] += 1
  end

  def test_a_child_fiber_records_into_the_request_that_spawned_it
    MP.start

    Fiber.new { record_one_call }.resume

    assert_equal(1, MP.stop[:sql][:calls])
  end

  def test_sibling_fibers_on_one_thread_do_not_share_a_profiler
    # Interleaved, the way a fiber-per-request server such as Falcon runs two in-flight
    # requests on one thread: each must keep its own tally.
    results = {}
    fibers =
      %i[a b].map do |name|
        Fiber.new do
          MP.start
          record_one_call
          Fiber.yield
          record_one_call
          results[name] = MP.stop[:sql][:calls]
        end
      end

    fibers.each(&:resume)
    fibers.each(&:resume)

    assert_equal({ a: 2, b: 2 }, results)
  end

  def test_a_hash_handed_back_from_a_previous_stop_keeps_its_duration
    MP.start
    record_one_call
    first = MP.stop

    MP.start(first)
    second = MP.stop

    assert_equal(first[:total_duration], second[:total_duration])
  end

  def test_a_hash_this_class_never_produced_yields_no_timings
    MP.start({ sql: { duration: 0.0, calls: 1 } })

    assert_nil(MP.stop)
  end

  def test_transfer_moves_the_state_out
    MP.start
    record_one_call

    moved = MP.transfer

    assert_equal(1, moved[:sql][:calls])
    assert_nil(MP.current)
  end
end
