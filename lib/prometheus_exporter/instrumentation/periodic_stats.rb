# frozen_string_literal: true

require_relative "../client"

module PrometheusExporter::Instrumentation
  class PeriodicStats
    # How long stop waits for a worker loop to notice it should end before killing it.
    STOP_TIMEOUT = 5

    # No catch-all: *args and **kwargs swallowed a misspelled keyword -- start(frequency:
    # 30, lables: {...}) ran happily and shipped metrics with no labels at all.
    def self.start(frequency:, client: nil)
      client ||= PrometheusExporter::Client.default

      raise ArgumentError.new("Expected frequency to be a number") if !(Numeric === frequency)

      raise ArgumentError.new("Expected frequency to be a positive number") if frequency < 0

      raise ArgumentError.new("Worker loop was not set") if !@worker_loop

      klass = self

      stop

      # After stop, not before: subclasses assign @worker_loop and then call super, and
      # the running thread re-reads the class ivar on every iteration, so the old thread
      # could execute the new closure while it was still being torn down.
      @stop_thread = false

      @started_in_pid = ::Process.pid
      @thread =
        Thread.new do
          while !@stop_thread
            begin
              @worker_loop.call
            rescue => e
              # The logger can raise too -- a descriptor closed by logrotate, a Rails
              # logger torn down at reload -- and that used to kill the thread silently,
              # stopping collection for good after one transient error.
              begin
                client.logger.error("#{klass} Prometheus Exporter Failed To Collect Stats #{e}")
              rescue StandardError
                nil
              end
            ensure
              sleep frequency
            end
          end
        end
    end

    def self.started?
      !!@thread&.alive?
    end

    # True when this process inherited a dead collection thread from its parent.
    def self.dead_after_fork?
      !@started_in_pid.nil? && @started_in_pid != ::Process.pid
    end

    def self.worker_loop(&blk)
      @worker_loop = blk
    end

    def self.stop
      # to avoid a warning
      @thread = nil if !defined?(@thread)

      if @thread&.alive?
        @stop_thread = true
        # wakeup only interrupts a sleep, not a blocking read, so a worker loop stuck on a
        # black-holed socket would hang join forever -- and start calls stop, so that hang
        # reaches application boot.
        begin
          @thread.wakeup
        rescue ThreadError
          nil
        end
        @thread.kill if !@thread.join(STOP_TIMEOUT)
      end
      @thread = nil
    end

    # Collection threads do not survive fork, and a forked child reports nothing at all
    # while started? simply answers false. Exposed for a caller that wants to check, but
    # not warned about from start: the README's own before_fork/after_fork pattern calls
    # start in exactly this situation, correctly.
    def self.warn_if_dead_after_fork(client)
      return if !dead_after_fork?

      client.logger.warn(
        "#{self} Prometheus Exporter collection thread did not survive fork; " \
          "restart it in the child (see the after_fork hooks in the README)",
      )
    rescue StandardError
      nil
    end
  end
end
