# frozen_string_literal: true

require_relative "prometheus_exporter/version"
require "json"

module PrometheusExporter
  # per: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
  DEFAULT_PORT = 9394
  DEFAULT_BIND_ADDRESS = "localhost"
  DEFAULT_PREFIX = "ruby_"
  # Frozen: the frozen_string_literal pragma does not freeze collections, and writing
  # into this constant changed the default for every metric in the process, including
  # ones registered beforehand.
  DEFAULT_LABEL = {}.freeze
  DEFAULT_TIMEOUT = 2
  DEFAULT_REALM = "Prometheus Exporter"

  class OjCompat
    def self.parse(obj)
      Oj.compat_load(obj)
    end

    def self.dump(obj)
      Oj.dump(obj, mode: :compat)
    end
  end

  def self.hostname
    @hostname ||=
      begin
        require "socket"
        Socket.gethostname
      rescue => e
        STDERR.puts "Unable to lookup hostname #{e}"
        "unknown-host"
      end
  end

  # An explicit :oj falls back to JSON when the gem is not installed, rather than handing
  # back OjCompat and raising NameError on the first dump -- which happens in the calling
  # thread, so inside a Sidekiq middleware's ensure, masking the job's own outcome.
  def self.detect_json_serializer(preferred)
    if preferred.nil?
      preferred = :oj if has_oj?
    end

    preferred == :oj && has_oj? ? OjCompat : JSON
  end

  @@has_oj = nil
  def self.has_oj?
    (
      @@has_oj ||=
        begin
          require "oj"
          :T
        rescue LoadError
          :F
        end
    ) == :T
  end
end
