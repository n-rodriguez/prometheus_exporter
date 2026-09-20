# frozen_string_literal: true

require "webrick"
require "timeout"
require "zlib"
require "stringio"

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @auth_send_metrics = opts[:auth_send_metrics] || false
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM
      @pid = Process.pid

      @metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_metrics_total",
          "Total metrics processed by exporter web.",
        )

      @sessions_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_sessions_total",
          "Total send_metric sessions processed by exporter web.",
        )

      @bad_metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_bad_metrics_total",
          "Total mis-handled metrics by collector.",
        )

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)

      @access_log, @logger = nil
      log_target = opts[:log_target]

      if @verbose
        @access_log = [
          [$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT],
          [$stderr, WEBrick::AccessLog::REFERER_LOG_FORMAT],
        ]
        @logger = WEBrick::Log.new(log_target || $stderr)
      else
        @access_log = []
        @logger = WEBrick::Log.new(log_target || "/dev/null")
      end

      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      # Built once, at startup: the file used to be re-read and re-parsed on every single
      # request, and an unreadable format only surfaced as a failing scrape. WEBrick
      # raises NotImplementedError on MD5 and bcrypt files, which is a ScriptError and so
      # escapes any `rescue =>` downstream.
      @basic_auth = build_basic_auth(@auth) if @auth

      if %w[ALL ANY].include?(@bind)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces"
        @bind = nil
      end

      @collector = opts[:collector] || Collector.new(logger: @logger)

      webrick_options = { Port: @port, BindAddress: @bind, Logger: @logger, AccessLog: @access_log }

      # Refused here and not only in the CLI: the single-process setup documented in the
      # README builds WebServer directly, and half a pair used to start a plaintext
      # listener while the operator believed /metrics was HTTPS.
      if opts[:tls_cert_file].nil? ^ opts[:tls_key_file].nil?
        raise ArgumentError, "tls_cert_file and tls_key_file must be supplied together"
      end

      if opts[:tls_cert_file] && opts[:tls_key_file]
        require "webrick/https"
        require "openssl"

        webrick_options[:SSLEnable] = true
        webrick_options[:SSLCertificate] = OpenSSL::X509::Certificate.new(
          File.read(opts[:tls_cert_file]),
        )
        webrick_options[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.read(opts[:tls_key_file]))
      end

      @server = WEBrick::HTTPServer.new(webrick_options)

      @server.mount_proc "/" do |req, res|
        res["Content-Type"] = "text/plain; charset=utf-8"
        if req.path == "/metrics"
          authenticate(req, res) if @auth

          res.status = 200
          if req.header["accept-encoding"].to_s.include?("gzip")
            sio = StringIO.new
            collected_metrics = metrics
            begin
              writer = Zlib::GzipWriter.new(sio)
              writer.write(collected_metrics)
            ensure
              writer.close
            end
            res.body = sio.string
            res.header["content-encoding"] = "gzip"
          else
            res.body = metrics
          end
        elsif req.path == "/send-metrics"
          # /send-metrics is the write surface: leaving it open while /metrics is
          # authenticated protects the reading of the data but not the forging of it.
          # Off by default all the same, because PrometheusExporter::Client cannot
          # authenticate yet, and turning it on without a client that can would drop every
          # metric silently.
          authenticate(req, res) if @auth && @auth_send_metrics

          handle_metrics(req, res)
        elsif req.path == "/ping"
          res.body = "PONG"
        else
          res.status = 404
          res.body =
            "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
        end
      end
    end

    def handle_metrics(req, res)
      @sessions_total.observe
      rejected = 0
      last_error_status = nil

      req.body do |block|
        begin
          @metrics_total.observe
          @collector.process(block)
        rescue => e
          # Keep draining the batch. Bailing out here used to abandon every later message
          # of a chunked session -- up to MAX_SOCKET_AGE seconds of metrics from that
          # process, of every type -- because one of them was malformed.
          @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n" if @verbose
          @bad_metrics_total.observe
          rejected += 1
          last_error_status = e.respond_to?(:status_code) ? e.status_code : 500
        end
      end

      if rejected > 0
        res.body = "Bad Metrics: #{rejected} message(s) rejected"
        res.status = last_error_status
      else
        res.body = "OK"
        res.status = 200
      end
    end

    def start
      @runner ||=
        Thread.start do
          begin
            @server.start
          rescue => e
            @logger.error "Failed to start prometheus collector web on port #{@port}: #{e}"
          end
        end
    end

    def stop
      @server.shutdown
    end

    def metrics
      metric_text = nil
      begin
        Timeout.timeout(@timeout) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        # we timed out ... bummer
        @logger.error "Generating Prometheus metrics text timed out"
      end

      metrics = []

      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0,
      )

      metrics << add_gauge("collector_rss", "total memory used by collector process", get_rss)

      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      <<~TEXT
      #{metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def get_rss
      begin
        File.read("/proc/#{@pid}/statm").split(" ")[1].to_i * PAGESIZE
      rescue StandardError
        0
      end
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    def authenticate(req, res)
      @basic_auth.authenticate(req, res)
    end

    def build_basic_auth(path)
      htpasswd = WEBrick::HTTPAuth::Htpasswd.new(path)
      # AutoReloadUserDB is on by default, which re-reads and re-parses the file on every
      # request -- and, now that the instance is shared, lets one thread clear the hash
      # while another reads it, answering 401 to a valid credential.
      WEBrick::HTTPAuth::BasicAuth.new(
        { Realm: @realm, UserDB: htpasswd, Logger: @logger, AutoReloadUserDB: false },
      )
      # MD5 raises NotImplementedError, a ScriptError that escapes `rescue =>`; bcrypt and
      # a malformed file raise plain StandardError. All three mean the same thing here.
    rescue NotImplementedError, StandardError => e
      raise ArgumentError,
            "htpasswd file #{path} is in a format WEBrick cannot read (#{e.message}). " \
              "Only DES crypt is supported; generate the file with " \
              "`htpasswd -cdb #{path} <user> <password>`."
    end
  end
end
