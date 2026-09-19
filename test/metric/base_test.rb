# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/metric"

module PrometheusExporter::Metric
  describe Base do
    let :counter do
      Counter.new("a_counter", "my amazing counter")
    end

    before do
      Base.default_prefix = ""
      Base.default_labels = {}
      Base.default_aggregation = nil
    end

    after do
      Base.default_prefix = ""
      Base.default_labels = {}
      Base.default_aggregation = nil
    end

    it "supports a dynamic prefix" do
      Base.default_prefix = "web_"
      counter.observe

      text = <<~TEXT
        # HELP web_a_counter my amazing counter
        # TYPE web_a_counter counter
        web_a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "supports default labels" do
      Base.default_labels = { foo: "bar" }

      counter.observe(2, baz: "bar")
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{foo="bar",baz="bar"} 2
        a_counter{foo="bar"} 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "uses specified labels over default labels when there is conflict" do
      Base.default_labels = { foo: "bar" }

      counter.observe(2, foo: "baz")
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{foo="baz"} 2
        a_counter{foo="bar"} 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "supports reset! for Gauge" do
      gauge = Gauge.new("test", "test")

      gauge.observe(999)
      gauge.observe(100, a: "a")
      gauge.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test gauge
      TEXT

      assert_equal(gauge.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Counter" do
      counter = Counter.new("test", "test")

      counter.observe(999)
      counter.observe(100, a: "a")
      counter.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test counter
      TEXT

      assert_equal(counter.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Histogram" do
      histogram = Histogram.new("test", "test")

      histogram.observe(999)
      histogram.observe(100, a: "a")
      histogram.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test histogram
      TEXT

      assert_equal(histogram.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Summary" do
      summary = Summary.new("test", "test")

      summary.observe(999)
      summary.observe(100, a: "a")
      summary.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test summary
      TEXT

      assert_equal(summary.to_prometheus_text.strip, text.strip)
    end

    it "creates a summary by default" do
      aggregation = Base.default_aggregation.new("test", "test")

      text = <<~TEXT
        # HELP test test
        # TYPE test summary
      TEXT

      assert_equal(aggregation.to_prometheus_text.strip, text.strip)
    end

    it "creates a histogram when configured" do
      Base.default_aggregation = Histogram
      aggregation = Base.default_aggregation.new("test", "test")

      text = <<~TEXT
        # HELP test test
        # TYPE test histogram
      TEXT

      assert_equal(aggregation.to_prometheus_text.strip, text.strip)
    end

    it "sanitizes a metric name that is not a valid Prometheus identifier" do
      assert_equal("bad_name", Base.sanitize_metric_name("bad name"))
      assert_equal("bad_name", Base.sanitize_metric_name("bad-name"))
      assert_equal("_0leading_digit", Base.sanitize_metric_name("0leading_digit"))
      assert_equal("_", Base.sanitize_metric_name(""))
    end

    it "renders a sanitized name while keeping the stored one untouched" do
      counter = Counter.new("bad name", "help")
      counter.observe

      assert_equal("bad name", counter.name)

      text = <<~TEXT
        # HELP bad_name help
        # TYPE bad_name counter
        bad_name 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "sanitizes the prefixed name, not the bare one" do
      Base.default_prefix = "web_"
      counter = Counter.new("0leading", "help")
      counter.observe

      text = <<~TEXT
        # HELP web_0leading help
        # TYPE web_0leading counter
        web_0leading 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "sanitizes a metric name carrying an injected exposition line" do
      counter = Counter.new("legit\n# TYPE injected counter\ninjected", "help")
      counter.observe

      text = <<~TEXT
        # HELP legit___TYPE_injected_counter_injected help
        # TYPE legit___TYPE_injected_counter_injected counter
        legit___TYPE_injected_counter_injected 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "accepts the identifier characters the exposition format allows" do
      assert_equal("ns:metric_total", Base.sanitize_metric_name("ns:metric_total"))
      assert_equal("_underscore", Base.sanitize_metric_name("_underscore"))
    end

    it "rejects an invalid metric name on the strict validator" do
      assert_raises(InvalidNameError) { Base.validate_metric_name!("bad name") }
      assert_equal("ok_name", Base.validate_metric_name!("ok_name"))
    end

    it "rejects a non-Hash set of default labels" do
      assert_raises(ArgumentError) { Base.default_labels = "not a hash" }
    end

    it "sanitizes an invalid default prefix at render time rather than refusing it" do
      Base.default_prefix = "bad-prefix_"
      counter.observe

      text = <<~TEXT
        # HELP bad_prefix_a_counter my amazing counter
        # TYPE bad_prefix_a_counter counter
        bad_prefix_a_counter 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "accepts an empty or nil default prefix" do
      Base.default_prefix = nil

      assert_equal("", Base.default_prefix)

      Base.default_prefix = "web_"

      assert_equal("web_", Base.default_prefix)
    end

    it "sanitizes a label name that is not a valid Prometheus identifier" do
      counter.observe(1, "bad\"key" => "v")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{bad_key="v"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "renders no forged series from a label name carrying quotes and a newline" do
      counter.observe(1, "bad\"key\nm2{x=\"y\"} 99\n#" => "v")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{bad_key_m2_x__y___99__="v"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "prefixes a sanitized label name that would start with a digit" do
      counter.observe(1, "0leading" => "v")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{_0leading="v"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "renders a label name only once when two keys sanitize to the same name" do
      counter.observe(1, "queue-name" => "first", "queue.name" => "second")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{queue_name="second"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "renders a label name only once when a symbol key collides with its string twin" do
      counter.observe(1, :queue_name => "first", "queue_name" => "second")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{queue_name="second"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "keeps an explicit label winning over a default one it collides with" do
      Base.default_labels = { job_name: "from_default" }

      counter.observe(1, "job_name" => "from_metric")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{job_name="from_metric"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "sanitizes a reserved label name Prometheus would refuse" do
      counter.observe(1, "__name__" => "evil")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{name__="evil"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "rejects a reserved label name on the strict validator" do
      assert_raises(InvalidLabelNameError) { Base.validate_label_name!("__name__") }
      assert_raises(InvalidLabelNameError) { Base.validate_label_name!("bad-key") }
      assert_equal("ok_key", Base.validate_label_name!("ok_key"))
    end

    it "aggregates observations whose labels came as nil with those that came as empty" do
      counter.observe(1, nil)
      counter.observe(2, {})

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter 3
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "renders one series when two colliding label sets differ only by key order" do
      counter.observe(1, "a-1" => "x", "b" => "y")
      counter.observe(2, "b" => "y", "a.1" => "x")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{a_1="x",b="y"} 3
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "renders a metric whose labels were stored as nil" do
      counter.observe(1, nil)
      gauge = Gauge.new("a_gauge", "help")
      gauge.observe(2, nil)
      histogram = Histogram.new("a_histogram", "help")
      histogram.observe(3, nil)
      summary = Summary.new("a_summary", "help")
      summary.observe(4, nil)

      assert_includes(counter.to_prometheus_text, "a_counter 1")
      assert_includes(gauge.to_prometheus_text, "a_gauge 2")
      assert_includes(histogram.to_prometheus_text, "a_histogram_count 1")
      assert_includes(summary.to_prometheus_text, "a_summary_count 1")
    end

    it "never raises while rendering, whatever the label names hold" do
      counter.observe(1, "" => "empty", "\n\"\\" => "control")

      counter.to_prometheus_text
    end

    it "sanitizes an invalid default label name at render time rather than refusing it" do
      Base.default_labels = { "bad-key" => "v" }
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{bad_key="v"} 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "sums two counter label sets that sanitize to the same series" do
      counter.observe(1, "job-name" => "a")
      counter.observe(5, "job_name" => "a")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{job_name="a"} 6
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "never lets a colliding label set make a counter go backwards" do
      counter.observe(1000, "job_name" => "a")

      assert_includes(counter.to_prometheus_text, 'a_counter{job_name="a"} 1000')

      counter.observe(1, "job-name" => "a")

      assert_includes(counter.to_prometheus_text, 'a_counter{job_name="a"} 1001')

      counter.observe(1000, "job-name" => "a")

      assert_includes(counter.to_prometheus_text, 'a_counter{job_name="a"} 2001')
    end

    it "refuses a gauge name that only sanitizes into a _total suffix" do
      assert_raises(ArgumentError) { Gauge.new("jobs.total", "help") }
      assert_raises(ArgumentError) { Gauge.new("jobs-total", "help") }
    end

    it "still refuses a gauge named with an explicit _total suffix" do
      assert_raises(ArgumentError) { Gauge.new("jobs_total", "help") }
    end

    it "keeps the latest reading when two gauge label sets sanitize to the same series" do
      gauge = Gauge.new("a_gauge", "my amazing gauge")
      gauge.observe(1, "job-name" => "a")
      gauge.observe(5, "job_name" => "a")

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{job_name="a"} 5
      TEXT

      assert_equal(text, gauge.to_prometheus_text)
    end

    it "merges two summary label sets that sanitize to the same series" do
      summary = Summary.new("a_summary", "my amazing summary")
      summary.observe(1, "job-name" => "a")
      summary.observe(5, "job_name" => "a")

      lines = summary.to_prometheus_text.lines.grep(/\Aa_summary_(sum|count)/)

      assert_equal(
        ["a_summary_sum{job_name=\"a\"} 6.0\n", "a_summary_count{job_name=\"a\"} 2\n"],
        lines,
      )
    end

    it "drops a user label named quantile, which a summary appends itself" do
      summary = Summary.new("a_summary", "my amazing summary")
      summary.observe(1, "quantile" => "a")
      summary.observe(5, "quantile" => "b")

      count_lines = summary.to_prometheus_text.lines.grep(/\Aa_summary_count/)

      assert_equal(["a_summary_count 2\n"], count_lines)
    end

    it "merges a series whose reserved label was stripped into the one it collides with" do
      summary = Summary.new("a_summary", "my amazing summary")
      summary.observe(99.0, "quantile" => "0.5")
      summary.observe(2.0)
      summary.observe(2.0)

      lines = summary.to_prometheus_text.lines.grep(/\Aa_summary_(sum|count)/)

      assert_equal(["a_summary_sum 103.0\n", "a_summary_count 3\n"], lines)
    end

    it "drops a user label named le, which a histogram appends itself" do
      histogram = Histogram.new("a_histogram", "my amazing histogram")
      histogram.observe(1, "le" => "a")
      histogram.observe(5, "le" => "b")

      count_lines = histogram.to_prometheus_text.lines.grep(/\Aa_histogram_count/)

      assert_equal(["a_histogram_count 2\n"], count_lines)
    end

    it "merges two histogram label sets that sanitize to the same series" do
      histogram = Histogram.new("a_histogram", "my amazing histogram")
      histogram.observe(1, "job-name" => "a")
      histogram.observe(5, "job_name" => "a")

      lines = histogram.to_prometheus_text.lines.grep(/\Aa_histogram_(sum|count)/)

      assert_equal(
        ["a_histogram_count{job_name=\"a\"} 2\n", "a_histogram_sum{job_name=\"a\"} 6.0\n"],
        lines,
      )
    end

    it "keeps accepting symbol and string label names that are valid" do
      counter.observe(1, foo: "a")
      counter.observe(2, "bar" => "b")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{foo="a"} 1
        a_counter{bar="b"} 2
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "escapes backslashes and newlines in help" do
      counter = Counter.new("test", "line one\nline two \\ end")
      counter.observe

      text = <<~TEXT
        # HELP test line one\\nline two \\\\ end
        # TYPE test counter
        test 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end

    it "keeps a help string free of control characters untouched" do
      counter = Counter.new("test", 'quotes " and {braces} are legal in help')
      counter.observe

      text = <<~TEXT
        # HELP test quotes " and {braces} are legal in help
        # TYPE test counter
        test 1
      TEXT

      assert_equal(text, counter.to_prometheus_text)
    end
  end
end
