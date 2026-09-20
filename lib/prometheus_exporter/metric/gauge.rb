# frozen_string_literal: true

module PrometheusExporter::Metric
  class Gauge < Base
    attr_reader :data

    def initialize(name, help)
      # Guards the published name, which is the sanitized one: "jobs.total" renders as
      # "jobs_total" and would otherwise slip past the very invariant this guard exists
      # for. sanitize_metric_name coerces, so a non-String name cannot fail here either.
      if Base.sanitize_metric_name(name).end_with?("_total")
        raise ArgumentError, "The metric name of gauge must not have _total suffix. Given: #{name}"
      end

      super
      reset!
    end

    def type
      "gauge"
    end

    def metric_text
      # A gauge is a snapshot, so colliding label sets are not summed -- that would double
      # a single measurement. The most recently stored one wins.
      group_by_rendered_labels(@data)
        .map { |_labels, text, keys| "#{prefix(@name)}#{text} #{@data[keys.last]}" }
        .join("\n")
    end

    def reset!
      @data = {}
    end

    def to_h
      @data.dup
    end

    def remove(labels)
      @data.delete(labels)
    end

    def observe(value, labels = {})
      labels ||= {}
      if value.nil?
        data.delete(labels)
      else
        raise ArgumentError, "value must be a number" if !(Numeric === value)
        @data[labels] = value
      end
    end

    alias_method :set, :observe

    def increment(labels = {}, value = 1)
      labels ||= {}
      @data[labels] ||= 0
      @data[labels] += value
    end

    def decrement(labels = {}, value = 1)
      labels ||= {}
      @data[labels] ||= 0
      @data[labels] -= value
    end
  end
end
