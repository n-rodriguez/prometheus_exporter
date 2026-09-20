# frozen_string_literal: true

require_relative "../client"

module PrometheusExporter::Instrumentation
  class Shoryuken
    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(worker, queue, msg, body)
      success = false
      # Initialised here, not only in the rescue below: a successful job used to report
      # shutdown: nil where Sidekiq reports false, so any logic testing for false silently
      # excluded every Shoryuken job.
      shutdown = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = yield
      success = true
      result
    rescue ::Shoryuken::Shutdown => e
      shutdown = true
      raise e
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start
      @client.send_json(
        type: "shoryuken",
        queue: queue,
        name: worker.class.name,
        success: success,
        shutdown: shutdown,
        duration: duration,
      )
    end
  end
end
