# frozen_string_literal: true

require_relative "../client"

module PrometheusExporter::Instrumentation
  class DelayedJob
    JOB_CLASS_REGEXP = /job_class: ((\w+:{0,2})+)/.freeze

    class << self
      def register_plugin(client: nil, include_module_name: false)
        instrumenter = self.new(client: client)
        return unless defined?(Delayed::Plugin)

        plugin =
          Class.new(Delayed::Plugin) do
            callbacks do |lifecycle|
              lifecycle.around(:invoke_job) do |job, *args, &block|
                max_attempts = Delayed::Worker.max_attempts
                # Sampled rather than counted on every invocation: two COUNTs per job, on
                # a predicate the stock schema does not index, cost more than the jobs
                # themselves on a busy worker.
                enqueued_count, pending_count = instrumenter.queue_depths(job.queue)
                instrumenter.call(
                  job,
                  max_attempts,
                  enqueued_count,
                  pending_count,
                  include_module_name,
                  *args,
                  &block
                )
              end
            end
          end

        Delayed::Worker.plugins << plugin
      end
    end

    # How long a queue-depth sample is reused before both COUNTs are issued again.
    QUEUE_DEPTH_TTL = 30

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
      @queue_depths = {}
      @queue_depths_mutex = Mutex.new
    end

    # [enqueued, pending] for a queue, recomputed at most once per QUEUE_DEPTH_TTL.
    def queue_depths(queue)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      @queue_depths_mutex.synchronize do
        cached = @queue_depths[queue]
        return cached[1] if cached && now - cached[0] < QUEUE_DEPTH_TTL

        depths = [
          Delayed::Job.where(queue: queue).count,
          Delayed::Job.where(attempts: 0, locked_at: nil, queue: queue).count,
        ]
        @queue_depths[queue] = [now, depths]
        depths
      end
    end

    def call(job, max_attempts, enqueued_count, pending_count, include_module_name, *args, &block)
      # Assigned first: everything below can raise, and the ensure used to compute
      # clock_gettime - nil, replacing the job's real error with a TypeError from the
      # metrics plugin.
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      success = false
      # No to_s on the match: it turned "no job_class in the handler" into "" rather than
      # nil, so the fallback below never fired and every Delayed::PerformableMethod
      # collapsed into one anonymous series.
      job_name = job.handler.to_s.match(JOB_CLASS_REGEXP).to_a[include_module_name ? 1 : 2]
      job_name ||= job.try(:name)
      latency = Time.current - job.run_at
      attempts = job.attempts + 1 # Increment because we're adding the current attempt
      result = block.call(job, *args)
      success = true
      result
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start

      @client.send_json(
        type: "delayed_job",
        name: job_name,
        queue_name: job.queue,
        success: success,
        duration: duration,
        latency: latency,
        attempts: attempts,
        max_attempts: max_attempts,
        enqueued: enqueued_count,
        pending: pending_count,
      )
    end
  end
end
