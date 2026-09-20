# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/instrumentation/unicorn"

class PrometheusUnicornInstrumentationTest < Minitest::Test
  def instrumenter(pid_file)
    PrometheusExporter::Instrumentation::Unicorn.new(pid_file: pid_file, listener_address: "/tmp/x")
  end

  def with_pid_file
    require "tmpdir"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "unicorn.pid")
      File.write(path, "#{Process.pid}\n")
      yield path
    end
  end

  def test_no_matching_worker_is_reported_as_zero
    with_pid_file do |path|
      instrument = instrumenter(path)

      # pgrep exits 1 when it matched nothing, which is a genuine "no workers left" --
      # the value an alert fires on, so it must still be reported.
      assert_equal(0, instrument.send(:worker_process_count))
    end
  end

  def test_a_broken_pgrep_yields_no_measurement
    with_pid_file do |path|
      instrument = instrumenter(path)
      # Stands in for pgrep being absent from the image: status 127, not 1.
      instrument.define_singleton_method(:worker_pgrep) { |_pid| `exit 127` }

      assert_nil(instrument.send(:worker_process_count))
    end
  end

  def test_an_absent_pid_file_yields_no_measurement
    assert_nil(instrumenter("/nonexistent/unicorn.pid").send(:worker_process_count))
  end
end
