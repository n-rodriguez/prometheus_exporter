# Must not fall below the gemspec floor: the image used to start from ruby:3.1-slim while
# the gemspec required >= 3.2.0, so `gem install` refused the very gem being packaged --
# and the only run that exercised this was the release itself, after the gem had already
# been pushed.
ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}-slim

# Redeclared after FROM: an ARG declared before it is only in scope for the FROM line, so
# --build-arg GEM_VERSION was silently ignored and the image shipped whatever RubyGems
# served as latest at build time -- under the tag of the version being released.
ARG GEM_VERSION=

# apt-get rather than apt, which warns that it has no stable CLI; no recommends, and the
# lists purged in the same layer so they do not ship inside the image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

RUN gem install --no-doc --version=${GEM_VERSION} prometheus_exporter

# Unprivileged: an image running as root puts any remote code execution in WEBrick at uid 0.
RUN useradd --create-home --shell /usr/sbin/nologin exporter
USER exporter

EXPOSE 9394
ENTRYPOINT ["prometheus_exporter", "-b", "ANY"]
