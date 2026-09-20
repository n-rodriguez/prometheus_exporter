# frozen_string_literal: true

module PrometheusExporter::Metric
  class Summary < Base
    DEFAULT_QUANTILES = [0.99, 0.9, 0.5, 0.1, 0.01]
    ROTATE_AGE = 120

    attr_reader :estimators, :count, :total

    def initialize(name, help, opts = {})
      super(name, help)
      reset!
      @quantiles = opts[:quantiles] || DEFAULT_QUANTILES
    end

    def reset!
      @buffers = [{}, {}]
      @last_rotated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @current_buffer = 0
      @counts = {}
      @sums = {}
    end

    def to_h
      data = {}
      @counts.each_key do |labels|
        data[labels] = { "count" => @counts[labels], "sum" => @sums[labels] }
      end
      data
    end

    def remove(labels)
      @counts.delete(labels)
      @sums.delete(labels)
      @buffers[0].delete(labels)
      @buffers[1].delete(labels)
    end

    def type
      "summary"
    end

    def calculate_quantiles(raw_data)
      sorted = raw_data.sort
      length = sorted.length
      result = {}

      if length > 0
        @quantiles.each { |quantile| result[quantile] = sorted[(length * quantile).ceil - 1] }
      end

      result
    end

    # Rotation is driven from here as well as from #observe: a summary that stops receiving
    # observations would otherwise serve its last quantiles forever, showing a healthy p99
    # for an endpoint that has gone silent.
    def calculate_all_quantiles
      rotate_if_needed

      result = {}
      @buffers.each { |buffer| buffer.each_key { |labels| result[labels] ||= [] } }
      result.each_key do |labels|
        raw_data = @buffers[0].fetch(labels, []) + @buffers[1].fetch(labels, [])
        result[labels] = calculate_quantiles(raw_data)
      end

      result.reject! { |_labels, quantiles| quantiles.empty? }
      result
    end

    # Iterates over the known label sets rather than over the quantiles: _sum and _count are
    # cumulative and must stay monotonic, so they keep being served once the observation
    # buffers have expired. Only the quantiles disappear, leaving a gap in the graph.
    # Colliding label sets are merged, their buffers concatenated and their totals summed.
    def metric_text
      rotate_if_needed

      text = +""
      first = true
      group_by_rendered_labels(@counts, "quantile").each do |rendered, rendered_text, keys|
        text << "\n" unless first
        first = false

        raw_data = keys.flat_map { |key| @buffers[0].fetch(key, []) + @buffers[1].fetch(key, []) }
        calculate_quantiles(raw_data).each do |quantile, value|
          with_quantile = rendered.merge("quantile" => quantile)
          text << "#{prefix(@name)}#{labels_text(with_quantile)} #{value.to_f}\n"
        end

        text << "#{prefix(@name)}_sum#{rendered_text} #{keys.sum { |key| @sums[key] }}\n"
        text << "#{prefix(@name)}_count#{rendered_text} #{keys.sum { |key| @counts[key] }}"
      end
      text
    end

    # makes sure we have storage
    def ensure_summary(labels)
      @buffers[0][labels] ||= []
      @buffers[1][labels] ||= []
      @sums[labels] ||= 0.0
      @counts[labels] ||= 0
      nil
    end

    # Catches up on every window that elapsed rather than rotating once per call: when this
    # is reached from a render after a long silence, a single rotation would keep serving
    # the other buffer's stale quantiles. Two catch-up rotations empty both buffers, which
    # is what "no observation for two windows" should look like.
    def rotate_if_needed
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = now - @last_rotated
      return nil if elapsed <= ROTATE_AGE

      # Both orderings below matter because this also runs from the render path, which the
      # web server wraps in Timeout. Clear a buffer before switching onto it, so an
      # interruption between the two cannot leave the live window staged for the next
      # clear; and only advance @last_rotated once the rotations are through, so an
      # interruption does not consume a rotation without performing it.
      rotations = (elapsed / ROTATE_AGE).floor
      [rotations, @buffers.length].min.times do
        target = @current_buffer == 0 ? 1 : 0
        @buffers[target].each_value(&:clear)
        @current_buffer = target
      end

      # Stay on the rotation grid instead of restarting it from now, so the window a sample
      # lives in does not depend on when /metrics happened to be scraped.
      @last_rotated = now - (elapsed % ROTATE_AGE)
      nil
    end

    # Only the current buffer is fed; #calculate_all_quantiles unions both at render time.
    # Writing to both doubled the memory a summary holds for no added coverage.
    def observe(value, labels = nil)
      labels ||= {}
      ensure_summary(labels)
      rotate_if_needed

      value = value.to_f
      @buffers[@current_buffer][labels] << value
      @sums[labels] += value
      @counts[labels] += 1
    end
  end
end
