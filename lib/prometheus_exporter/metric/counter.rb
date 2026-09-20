# frozen_string_literal: true

module PrometheusExporter::Metric
  class Counter < Base
    attr_reader :data

    def initialize(name, help)
      super
      reset!
    end

    def type
      "counter"
    end

    def reset!
      @data = {}
    end

    def metric_text
      # Colliding label sets are summed: a counter must never go backwards, and dropping
      # one of them would take its increments with it.
      group_by_rendered_labels(@data)
        .map { |_labels, text, keys| "#{prefix(@name)}#{text} #{keys.sum { |key| @data[key] }}" }
        .join("\n")
    end

    def to_h
      @data.dup
    end

    def remove(labels)
      @data.delete(labels)
    end

    def observe(increment = 1, labels = {})
      labels ||= {}
      @data[labels] ||= 0
      @data[labels] += increment
    end

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

    def reset(labels = {}, value = 0)
      labels ||= {}
      @data[labels] = value
    end
  end
end
