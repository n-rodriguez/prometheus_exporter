# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "prometheus_exporter/version"

Gem::Specification.new do |spec|
  spec.name = "prometheus_exporter"
  spec.version = PrometheusExporter::VERSION
  spec.authors = ["Sam Saffron"]
  spec.email = ["sam.saffron@gmail.com"]

  spec.summary = "Prometheus Exporter"
  spec.description = "Prometheus metric collector and exporter for Ruby"
  spec.homepage = "https://github.com/discourse/prometheus_exporter"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["README.md", "CHANGELOG", "LICENSE.txt", "lib/**/*.rb", "exe/*"]

  spec.bindir = "exe"
  spec.executables = ["prometheus_exporter"]

  spec.require_paths = ["lib"]

  # rubygems_mfa_required matters here because publication is automated with a long-lived
  # API key: without it, a leaked key alone is enough to push a release.
  spec.metadata = {
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
  }

  # Declared because lib/ requires them unconditionally and they stopped being default
  # gems: on Ruby 4.0, logger, json and timeout all report default_gem? false, so a
  # non-Rails application installing this gem got a LoadError at boot. CI missed it
  # because every appraisal gemfile pulls in activesupport, which depends on logger.
  spec.add_dependency "json"
  spec.add_dependency "logger"
  spec.add_dependency "timeout"
  spec.add_dependency "webrick"
end
