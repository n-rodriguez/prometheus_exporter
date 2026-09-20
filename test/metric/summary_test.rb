# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/metric"

module PrometheusExporter::Metric
  describe Summary do
    let :summary do
      Summary.new("a_summary", "my amazing summary")
    end

    before { Base.default_prefix = "" }

    it "can correctly gather a summary with custom quantiles" do
      summary = Summary.new("custom", "custom summary", quantiles: [0.4, 0.6])

      (1..10).each { |i| summary.observe(i) }

      expected = <<~TEXT
        # HELP custom custom summary
        # TYPE custom summary
        custom{quantile="0.4"} 4.0
        custom{quantile="0.6"} 6.0
        custom_sum 55.0
        custom_count 10
      TEXT

      assert_equal(summary.to_prometheus_text, expected)
    end

    it "can correctly gather a summary over multiple labels" do
      summary.observe(0.1, nil)
      summary.observe(0.2)
      summary.observe(0.610001)
      summary.observe(0.610001)

      summary.observe(0.1, name: "bob", family: "skywalker")
      summary.observe(0.7, name: "bob", family: "skywalker")
      summary.observe(0.99, name: "bob", family: "skywalker")

      expected = <<~TEXT
        # HELP a_summary my amazing summary
        # TYPE a_summary summary
        a_summary{quantile="0.99"} 0.610001
        a_summary{quantile="0.9"} 0.610001
        a_summary{quantile="0.5"} 0.2
        a_summary{quantile="0.1"} 0.1
        a_summary{quantile="0.01"} 0.1
        a_summary_sum 1.520002
        a_summary_count 4
        a_summary{name="bob",family="skywalker",quantile="0.99"} 0.99
        a_summary{name="bob",family="skywalker",quantile="0.9"} 0.99
        a_summary{name="bob",family="skywalker",quantile="0.5"} 0.7
        a_summary{name="bob",family="skywalker",quantile="0.1"} 0.1
        a_summary{name="bob",family="skywalker",quantile="0.01"} 0.1
        a_summary_sum{name="bob",family="skywalker"} 1.79
        a_summary_count{name="bob",family="skywalker"} 3
      TEXT

      assert_equal(summary.to_prometheus_text, expected)
    end

    it "can correctly gather a summary" do
      summary.observe(0.1)
      summary.observe(0.2)
      summary.observe(0.610001)
      summary.observe(0.610001)
      summary.observe(0.610001)
      summary.observe(0.910001)
      summary.observe(0.1)

      expected = <<~TEXT
        # HELP a_summary my amazing summary
        # TYPE a_summary summary
        a_summary{quantile="0.99"} 0.910001
        a_summary{quantile="0.9"} 0.910001
        a_summary{quantile="0.5"} 0.610001
        a_summary{quantile="0.1"} 0.1
        a_summary{quantile="0.01"} 0.1
        a_summary_sum 3.1400040000000002
        a_summary_count 7
      TEXT

      assert_equal(summary.to_prometheus_text, expected)
    end

    it "can correctly rotate quantiles" do
      Process.stub(:clock_gettime, 1.0) do
        summary.observe(0.1)
        summary.observe(0.2)
        summary.observe(0.6)
      end

      Process.stub(:clock_gettime, 1.0 + Summary::ROTATE_AGE + 1.0) { summary.observe(300) }

      Process.stub(:clock_gettime, 1.0 + (Summary::ROTATE_AGE * 2) + 1.1) do
        summary.observe(100)
        summary.observe(200)
        summary.observe(300)

        expected = <<~TEXT
          # HELP a_summary my amazing summary
          # TYPE a_summary summary
          a_summary{quantile="0.99"} 300.0
          a_summary{quantile="0.9"} 300.0
          a_summary{quantile="0.5"} 200.0
          a_summary{quantile="0.1"} 100.0
          a_summary{quantile="0.01"} 100.0
          a_summary_sum 900.9
          a_summary_count 7
        TEXT

        assert_equal(summary.to_prometheus_text, expected)
      end
    end

    it "stops serving quantiles once observations stop, but keeps sum and count" do
      Process.stub(:clock_gettime, 1.0) { 5.times { summary.observe(5.0) } }

      Process.stub(:clock_gettime, 1.0 + (Summary::ROTATE_AGE * 2) + 1.0) do
        expected = <<~TEXT
          # HELP a_summary my amazing summary
          # TYPE a_summary summary
          a_summary_sum 25.0
          a_summary_count 5
        TEXT

        assert_equal(expected, summary.to_prometheus_text)
      end
    end

    it "still serves quantiles when a single rotation window has elapsed" do
      Process.stub(:clock_gettime, 1.0) { 5.times { summary.observe(5.0) } }

      Process.stub(:clock_gettime, 1.0 + Summary::ROTATE_AGE + 1.0) do
        expected = <<~TEXT
          # HELP a_summary my amazing summary
          # TYPE a_summary summary
          a_summary{quantile="0.99"} 5.0
          a_summary{quantile="0.9"} 5.0
          a_summary{quantile="0.5"} 5.0
          a_summary{quantile="0.1"} 5.0
          a_summary{quantile="0.01"} 5.0
          a_summary_sum 25.0
          a_summary_count 5
        TEXT

        assert_equal(expected, summary.to_prometheus_text)
      end
    end

    it "keeps serving samples for the whole two-window retention" do
      Process.stub(:clock_gettime, 1000.0) { summary.observe(5.0) }

      # 119 s after the observation, a first window boundary has been crossed but the
      # sample still belongs to the retained buffer.
      Process.stub(:clock_gettime, 1119.0) do
        assert_includes(summary.to_prometheus_text, 'a_summary{quantile="0.99"} 5.0')
      end

      # 239 s after it, the second window has not fully elapsed either.
      Process.stub(:clock_gettime, 1239.0) do
        assert_includes(summary.to_prometheus_text, 'a_summary{quantile="0.99"} 5.0')
      end
    end

    it "lets a user label named quantile lose against the real quantile label" do
      summary.observe(5.0, "quantile" => "spoofed")

      quantile_lines = summary.to_prometheus_text.lines.grep(/\Aa_summary\{/)

      assert_equal(
        [
          "a_summary{quantile=\"0.99\"} 5.0\n",
          "a_summary{quantile=\"0.9\"} 5.0\n",
          "a_summary{quantile=\"0.5\"} 5.0\n",
          "a_summary{quantile=\"0.1\"} 5.0\n",
          "a_summary{quantile=\"0.01\"} 5.0\n",
        ],
        quantile_lines,
      )
    end

    it "stores each observation once across both buffers" do
      100.times { summary.observe(1.0) }

      stored = summary.instance_variable_get(:@buffers).sum { |b| b.values.sum(&:length) }

      assert_equal(100, stored)
    end

    it "can correctly return data set" do
      summary.observe(0.1, name: "bob", family: "skywalker")
      summary.observe(0.7, name: "bob", family: "skywalker")
      summary.observe(0.99, name: "bob", family: "skywalker")

      key = { name: "bob", family: "skywalker" }
      val = { "count" => 3, "sum" => 1.79 }

      assert_equal(summary.to_h, key => val)
    end

    it "can correctly remove data" do
      summary.observe(0.1, name: "bob", family: "skywalker")
      summary.observe(0.7, name: "bob", family: "skywalker")
      summary.observe(0.99, name: "bob", family: "skywalker")

      summary.observe(0.1, name: "jane", family: "skywalker")
      summary.observe(0.2, name: "jane", family: "skywalker")

      summary.remove(name: "jane", family: "skywalker")

      key = { name: "bob", family: "skywalker" }
      val = { "count" => 3, "sum" => 1.79 }

      assert_equal(summary.to_h, key => val)
    end
  end
end
