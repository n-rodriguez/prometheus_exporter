# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "socket"

# The CLI had no coverage at all: runner_test.rb injects doubles straight into Runner.new,
# which bypasses the option parsing, the ObjectSpace discovery and the exit codes -- so
# every CLI defect sailed through a green sixteen-cell matrix.
class PrometheusExporterCliTest < Minitest::Test
  EXE = File.expand_path("../exe/prometheus_exporter", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # Runs the CLI and returns [stdout + stderr, status]. Every invocation here is expected
  # to exit during option handling; the deadline is what makes a missing guard show up as
  # a failing test rather than as a suite that hangs on the exporter's trailing sleep.
  DEADLINE = 15

  def run_cli(*args)
    output = +""
    status = nil

    Open3.popen2e(RbConfig.ruby, "-I", LIB, EXE, *args) do |_stdin, out, wait_thread|
      reader = Thread.new { output << out.read }

      if wait_thread.join(DEADLINE).nil?
        Process.kill("KILL", wait_thread.pid)
        reader.join(1)
        flunk("the CLI did not exit within #{DEADLINE}s for #{args.inspect}")
      end

      reader.join(1)
      status = wait_thread.value
    end

    [output, status]
  end

  def test_it_refuses_a_port_out_of_range
    output, status = run_cli("-p", "99999")

    refute_predicate(status, :success?)
    assert_match(/between 1 and 65535/, output)
  end

  def test_it_refuses_a_label_that_is_not_json
    output, status = run_cli("--label", "env=prod")

    refute_predicate(status, :success?)
    assert_match(/must be a JSON object/, output)
  end

  def test_it_refuses_a_label_that_is_json_but_not_an_object
    output, status = run_cli("--label", '"oops"')

    refute_predicate(status, :success?)
    assert_match(/must be a JSON object, got String/, output)
  end

  def test_it_refuses_half_a_tls_pair
    output, status = run_cli("--tls-cert-file", "cert.pem")

    refute_predicate(status, :success?)
    assert_match(/must be supplied together/, output)
  end

  def test_it_refuses_auth_send_metrics_without_auth
    output, status = run_cli("--auth-send-metrics")

    refute_predicate(status, :success?)
    assert_match(/requires --auth/, output)
  end

  def test_it_refuses_an_auth_file_it_cannot_read
    output, status = run_cli("--auth", "/nonexistent/htpasswd")

    refute_predicate(status, :success?)
    assert_match(/AUTH file/, output)
  end

  def test_it_refuses_a_collector_file_defining_no_collector
    with_file("empty_collector.rb", "class NotACollector\nend\n") do |path|
      output, status = run_cli("-c", path)

      refute_predicate(status, :success?)
      assert_match(/inheriting off PrometheusExporter::Server::CollectorBase/, output)
    end
  end

  def test_it_refuses_a_collector_file_defining_two_unrelated_ones
    source = <<~RUBY
      class OneCollector < PrometheusExporter::Server::CollectorBase
      end

      class AnotherCollector < PrometheusExporter::Server::CollectorBase
      end
    RUBY

    with_file("two_collectors.rb", source) do |path|
      output, status = run_cli("-c", path)

      refute_predicate(status, :success?)
      assert_match(/must define exactly one/, output)
    end
  end

  def test_it_accepts_a_collector_file_declaring_a_base_next_to_the_real_class
    source = <<~RUBY
      class AbstractCollector < PrometheusExporter::Server::CollectorBase
      end

      class RealCollector < AbstractCollector
      end

      # Nothing below runs: the exporter is killed once it reports what it selected.
    RUBY

    with_file("base_and_real.rb", source) do |path|
      output = run_cli_until_startup("-c", path)

      assert_match(/Using custom collector RealCollector/, output)
    end
  end

  def test_it_refuses_a_type_collector_file_defining_none
    with_file("no_type_collector.rb", "class StillNotACollector\nend\n") do |path|
      output, status = run_cli("-a", path)

      refute_predicate(status, :success?)
      assert_match(/inheriting off PrometheusExporter::Server::TypeCollector/, output)
    end
  end

  private

  # For the cases where the CLI is expected to start rather than exit: it is killed once
  # it has logged what it selected.
  def run_cli_until_startup(*args)
    output = +""

    port = free_port

    Open3.popen2e(
      RbConfig.ruby,
      "-I",
      LIB,
      EXE,
      "-p",
      port.to_s,
      *args,
    ) do |_stdin, out, wait_thread|
      reader =
        Thread.new do
          while (line = out.gets)
            output << line
            break if line.include?("Starting prometheus exporter")
          end
        end
      reader.join(DEADLINE)
      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        # Already gone, which is the case when it aborted instead of starting.
      end
      wait_thread.join(DEADLINE)
    end

    output
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def with_file(name, source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, source)
      yield path
    end
  end
end
