# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Dev libs
# Pinned by SHA: an unpinned git dependency resolves that repository's default
# branch head on every CI run, so a force-push there executes arbitrary Ruby in a
# job holding a write-scoped token.
gem "appraisal",
    git: "https://github.com/thoughtbot/appraisal.git",
    ref: "602cdd9b5f8cb8f36992733422f69312b172f427"
gem "activerecord", "~> 7.1"
gem "bundler", ">= 2.1.4"
gem "m"
gem "mini_racer"
gem "minitest"
gem "minitest-mock"
gem "minitest-stub-const"
gem "oj"
gem "rack-test"
gem "rake"
gem "redis"
gem "syntax_tree"
gem "syntax_tree-disable_ternary"
# != , not !x == y: the latter parses as (!RUBY_ENGINE) == "jruby", which is always
# false, so raindrops was never installed and the Unicorn instrumentation was never
# exercised by any matrix cell.
gem "raindrops", "~> 0.19" if RUBY_ENGINE != "jruby"
gem "simplecov"

# Dev tools / linter
gem "guard", require: false
gem "guard-minitest", require: false
gem "rubocop", require: false
gem "rubocop-discourse", require: false
