# frozen_string_literal: true

require_relative "test_helper"
require "prometheus_exporter/client"

class PrometheusExporterTest < Minitest::Test
  def test_find_the_correct_registered_metric
    client = PrometheusExporter::Client.new

    # register a metrics for testing
    counter_metric = client.register(:counter, "counter_metric", "helping")

    # when the given name doesn't match any existing metric, it returns nil
    result = client.find_registered_metric("not_registered")
    assert_nil(result)

    # when the given name matches an existing metric, it returns this metric
    result = client.find_registered_metric("counter_metric")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given type doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge)
    assert_nil(result)

    # when the given name and type match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter)
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", help: "not helping")
    assert_nil(result)

    # when the given name and help match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", help: "helping")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help and type don't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge, help: "not helping")
    assert_nil(result)

    # when the given name, type, and help all match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter, help: "helping")
    assert_equal(counter_metric, result)
  end

  def test_standard_values
    client = PrometheusExporter::Client.new
    counter_metric = client.register(:counter, "counter_metric", "helping")
    assert_equal(false, counter_metric.standard_values("value", "key").has_key?(:opts))

    expected_quantiles = { quantiles: [0.99, 9] }
    summary_metric = client.register(:summary, "summary_metric", "helping", expected_quantiles)
    assert_equal(expected_quantiles, summary_metric.standard_values("value", "key")[:opts])
  end

  def test_close_socket_on_error
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :error

    client =
      PrometheusExporter::Client.new(logger: logger, port: 321, process_queue_once_and_stop: true)
    client.send("put a message in the queue")

    assert_includes(
      logs.string,
      "Prometheus Exporter, failed to send message Connection refused - connect(2) for \"localhost\" port 321",
    )
  end

  def test_overriding_logger
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :warn

    client =
      PrometheusExporter::Client.new(
        logger: logger,
        max_queue_size: 1,
        process_queue_once_and_stop: true,
      )
    client.send("put a message in the queue")
    client.send("put a second message in the queue to trigger the logger")

    assert_includes(logs.string, "dropping message cause queue is full")
  end

  def test_tls_is_enabled_by_a_ca_file_alone
    client = PrometheusExporter::Client.new(tls_ca_file: "some-ca.pem")

    assert(client.__send__(:use_ssl?))
  end

  def test_a_client_certificate_without_its_key_is_refused
    assert_raises(ArgumentError) do
      PrometheusExporter::Client.new(tls_ca_file: "some-ca.pem", tls_cert_file: "cert.pem")
    end

    assert_raises(ArgumentError) do
      PrometheusExporter::Client.new(tls_ca_file: "some-ca.pem", tls_key_file: "key.pem")
    end
  end

  def test_no_tls_configuration_leaves_ssl_off
    client = PrometheusExporter::Client.new

    refute(client.__send__(:use_ssl?))
  end

  def test_dropping_a_message_never_blocks_the_calling_thread
    client = PrometheusExporter::Client.new(max_queue_size: 1)
    # No worker thread, so the queue state is entirely determined by this test: otherwise
    # the worker may drain it and the drop path is never reached.
    def client.ensure_worker_thread!
    end

    queue = client.instance_variable_get(:@queue)
    popped_non_block = []
    queue.define_singleton_method(:pop) do |non_block = false|
      popped_non_block << non_block
      super(non_block)
    end

    client.send("a")
    client.send("b")
    client.send("c")

    assert_equal([true, true], popped_non_block)
    assert_equal(1, queue.length)
  end

  def test_the_drop_path_survives_a_queue_emptied_underneath_it
    client = PrometheusExporter::Client.new(max_queue_size: 1)
    def client.ensure_worker_thread!
    end

    queue = client.instance_variable_get(:@queue)
    queue.define_singleton_method(:length) { 99 }

    client.send("a")
    queue.clear

    client.send("b")
  end

  def test_a_client_certificate_without_a_ca_still_enables_tls
    with_self_signed_pair do |cert_file, key_file|
      client = PrometheusExporter::Client.new(tls_cert_file: cert_file, tls_key_file: key_file)

      assert(client.__send__(:use_ssl?))
    end
  end

  # A client certificate is read at construction time, so it has to exist on disk.
  def with_self_signed_pair
    require "openssl"
    require "tmpdir"

    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=test")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))

    Dir.mktmpdir do |dir|
      cert_file = File.join(dir, "cert.pem")
      key_file = File.join(dir, "key.pem")
      File.write(cert_file, cert.to_pem)
      File.write(key_file, key.to_pem)
      yield cert_file, key_file
    end
  end
end
