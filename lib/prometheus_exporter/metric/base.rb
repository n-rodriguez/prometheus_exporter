# frozen_string_literal: true

module PrometheusExporter::Metric
  # Raised when a metric name would not survive the exposition format.
  class InvalidNameError < ArgumentError
  end

  # Raised when a label name would not survive the exposition format.
  class InvalidLabelNameError < ArgumentError
  end

  class Base
    # The exposition format offers no escaping for metric and label names, so anything
    # outside these two shapes has to be refused rather than rendered.
    # Metric names may carry colons, label names may not.
    # https://prometheus.io/docs/concepts/data_model/
    METRIC_NAME_REGEX = /\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/
    LABEL_NAME_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    # Public so callers that ingest untrusted payloads can reject them before a metric
    # is ever registered, rather than discovering the problem at render time.
    def self.validate_metric_name!(name)
      name = name.to_s
      if !name.match?(METRIC_NAME_REGEX)
        raise InvalidNameError, "metric name #{name.inspect} is not a valid Prometheus identifier"
      end
      name
    end

    def self.validate_label_name!(name)
      name = name.to_s
      if !name.match?(LABEL_NAME_REGEX) || reserved_label_name?(name)
        raise InvalidLabelNameError,
              "label name #{name.inspect} is not a valid Prometheus identifier"
      end
      name
    end

    # Prometheus reserves every label name starting with two underscores for its own use
    # (__name__ above all) and rejects a scrape that carries one.
    def self.reserved_label_name?(name)
      name.start_with?("__")
    end

    # Nothing on the payload path may raise: a metric is built straight from an untrusted
    # payload, and an exception there aborts the rest of the client's chunked batch while
    # the server still answers 200. Names are therefore coerced into the identifier shape,
    # the way Prometheus relabelling does. Callers that can still refuse a payload cleanly
    # use validate_metric_name! instead.
    def self.sanitize_metric_name(name)
      name = name.to_s
      return name if name.match?(METRIC_NAME_REGEX)

      name = name.gsub(/[^a-zA-Z0-9_:]/, "_")
      name = "_#{name}" if !name.match?(/\A[a-zA-Z_:]/)
      name
    end

    # Same reasoning one level down, with one difference: a label name may not carry a
    # colon, and type collectors only turn their stored payloads into observations while
    # /metrics is being served, so raising here would answer 500 for every metric of every
    # process rather than lose one batch.
    # Memoized: every series of every scrape sanitizes each of its label names, while the
    # set of distinct names an exporter sees is small and stable. The cache stops growing
    # past SANITIZED_CACHE_LIMIT so a client minting label names cannot make it a leak.
    SANITIZED_CACHE_LIMIT = 10_000
    @sanitized_label_names = {}

    def self.sanitize_label_name(name)
      cached = @sanitized_label_names[name]
      return cached if cached

      sanitized = uncached_sanitize_label_name(name.to_s)
      @sanitized_label_names[name] = sanitized if @sanitized_label_names.length <
        SANITIZED_CACHE_LIMIT
      sanitized
    end

    def self.uncached_sanitize_label_name(name)
      return name if name.match?(LABEL_NAME_REGEX) && !reserved_label_name?(name)

      name = name.gsub(/[^a-zA-Z0-9_]/, "_")
      name = name.sub(/\A_+/, "") if reserved_label_name?(name)
      name = "_#{name}" if !name.match?(/\A[a-zA-Z_]/)
      name
    end

    @default_prefix = nil if !defined?(@default_prefix)
    @default_labels = nil if !defined?(@default_labels)
    @default_aggregation = nil if !defined?(@default_aggregation)

    # prefix applied to all metrics
    def self.default_prefix=(name)
      # Stored as given: #prefix sanitizes the prefixed name at render time, so refusing
      # here would break an operator whose prefix rendered fine before, and for no gain.
      @default_prefix = name.to_s
    end

    def self.default_prefix
      @default_prefix.to_s
    end

    # Label names are sanitized at render time like any other, so a bad name is not
    # refused here either. A non-Hash is, since there is nothing to sanitize it into and
    # it would otherwise surface as a NoMethodError out of the first render.
    def self.default_labels=(labels)
      labels ||= {}
      if !labels.is_a?(Hash)
        raise ArgumentError, "default labels must be a Hash, got #{labels.class}"
      end

      @default_labels = labels
    end

    def self.default_labels
      @default_labels || {}
    end

    def self.default_aggregation=(aggregation)
      @default_aggregation = aggregation
    end

    def self.default_aggregation
      @default_aggregation ||= Summary
    end

    attr_accessor :help, :data
    attr_reader :name

    # Stores the name as given: a caller may index metrics under it, and rewriting it here
    # would change that key behind their back. The coercion happens in #prefix, on the
    # rendering path only.
    def name=(name)
      @name = name.to_s
    end

    def initialize(name, help)
      self.name = name
      @help = help
    end

    def type
      raise "Not implemented"
    end

    def metric_text
      raise "Not implemented"
    end

    def reset!
      raise "Not implemented"
    end

    def to_h
      raise "Not implemented"
    end

    def from_json(json)
      json = JSON.parse(json) if String === json
      self.name = json["name"]
      @help = json["help"]
      @data = json["data"]
      if Hash === json["data"]
        @data = {}
        json["data"].each do |k, v|
          k = JSON.parse(k)
          k = Hash[k.map { |k1, v1| [k1.to_sym, v1] }]
          @data[k] = v
        end
      end
    end

    # Sanitizes the prefixed name rather than the bare one: only their concatenation is
    # what actually reaches the exposition.
    def prefix(name)
      Base.sanitize_metric_name(Base.default_prefix + name.to_s)
    end

    # Sanitized name => escaped value, in the order the labels will be rendered.
    #
    # Two distinct keys can sanitize to the same name, and a Symbol key collides with its
    # String twin. Prometheus rejects a whole scrape on a duplicate label name, so a name
    # appears once, keeping the last value: default labels are merged first, so this
    # preserves the documented precedence of an explicit label over a default one.
    def rendered_label_pairs(labels)
      labels = Base.default_labels.merge(labels || {})

      rendered = {}
      labels.each do |key, value|
        key = Base.sanitize_label_name(key)
        value = value.to_s
        value = escape_value(value) if needs_escape?(value)
        rendered[key] = value
      end
      rendered
    end

    def labels_text(labels)
      labels_text_from(rendered_label_pairs(labels))
    end

    def labels_text_from(rendered)
      return nil if rendered.empty?

      "{#{rendered.map { |key, value| "#{key}=\"#{value}\"" }.join(",")}}"
    end

    # Two stored label sets that differ only by characters the sanitizer rewrites render
    # the same series, and Prometheus rejects a whole scrape carrying a duplicate series.
    # Keep one entry per rendered form, the last one, as colliding label names are
    # resolved.
    #
    # reserved_label names a label the metric type appends itself ("quantile", "le"): a
    # user label of that name is dropped before deduplication, otherwise two series that
    # differ only by it would still collide on the generated line.
    #
    # Collisions are grouped rather than resolved in favour of one member: dropping the
    # others would lose their observations, and for a counter it would make the exported
    # value go backwards, which Prometheus reads as a reset. Each metric type aggregates
    # its group the way its own semantics require.
    #
    # Yields [labels_to_render, rendered_text, stored_keys] so callers neither recompute
    # labels_text nor lose the keys they need to read their own stores with.
    def group_by_rendered_labels(data, reserved_label = nil)
      groups = {}
      data.each_key do |stored|
        # A stored key may be nil: collectors reach observe through
        # payload.fetch("custom_labels", {}), which yields nil on an explicit JSON null.
        labels = stored || {}
        rendered_labels = labels
        if reserved_label
          rendered_labels =
            labels.reject { |key, _value| Base.sanitize_label_name(key) == reserved_label }
        end

        # Keyed on the rendered hash, not on the rendered string: Hash equality and
        # hashing ignore insertion order, which is exactly the identity a series has. Two
        # payloads listing the same labels in a different order are the same series, and
        # Prometheus rejects a scrape carrying both.
        rendered = rendered_label_pairs(rendered_labels)
        group = groups[rendered]
        if group
          group[2] << stored
        else
          groups[rendered] = [rendered_labels, labels_text_from(rendered), [stored]]
        end
      end
      groups.values
    end

    def to_prometheus_text
      <<~TEXT
        # HELP #{prefix(name)} #{escape_help(help)}
        # TYPE #{prefix(name)} #{type}
        #{metric_text}
      TEXT
    end

    private

    def escape_value(str)
      str.gsub(/[\n"\\]/m) do |m|
        if m == "\n"
          "\\n"
        else
          "\\#{m}"
        end
      end
    end

    def needs_escape?(str)
      str.match?(/[\n"\\]/m)
    end

    # The HELP line ends at the first newline, so an unescaped one lets a payload write
    # arbitrary exposition lines of its own. Quotes need no escaping here.
    def escape_help(str)
      str
        .to_s
        .gsub(/[\n\\]/) do |m|
          if m == "\n"
            "\\n"
          else
            "\\\\"
          end
        end
    end
  end
end
