# syntax=docker/dockerfile:1
#
# All-in-one DNSTAP2 image — DNS-collector + Prometheus + Loki + Grafana in a
# SINGLE container, supervised by supervisord. Everything except InfoBlox and
# the DNS server (which stay external and dial dnstap into :6001).
#
# This is the monolithic counterpart to ../stack (one container per service).
# Use this when you want a single image to ship/run; use ../stack when you want
# to restart/upgrade services independently. The four processes talk to each
# other over localhost inside the container.
#
# Build:  docker build -t dnstap2-allinone docker/allinone
# Run:    docker run -d --name dnstap2 \
#           -p 6001:6001 -p 3000:3000 -p 9090:9090 -p 3100:3100 dnstap2-allinone
#
# On Apple Silicon add: --build-arg TARGETARCH=arm64

ARG DNSCOL_VERSION=2.2.3
ARG PROM_VERSION=2.53.0
ARG LOKI_VERSION=2.9.8
ARG GRAFANA_VERSION=10.4.2
ARG TARGETARCH=amd64

# ---------------------------------------------------------------------------
# Stage 1: fetch every upstream binary (pinned to match the native installers)
# ---------------------------------------------------------------------------
FROM debian:12-slim AS fetch
ARG DNSCOL_VERSION
ARG PROM_VERSION
ARG LOKI_VERSION
ARG GRAFANA_VERSION
ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates tar unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fetch
RUN mkdir -p /out

# DNS-collector (dnstap receiver)
RUN set -eux; \
    url="https://github.com/dmachard/DNS-collector/releases/download/v${DNSCOL_VERSION}/DNS-collector_${DNSCOL_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fSL --retry 3 -o dc.tgz "$url"; mkdir dc; tar -xzf dc.tgz -C dc; \
    bin="$(find dc -type f \( -iname 'DNScollector' -o -iname 'DNS-collector' -o -iname 'go-dnscollector' -o -iname 'dnscollector' \) | head -1)"; \
    [ -n "$bin" ] || bin="$(find dc -maxdepth 2 -type f -perm -u+x ! -iname '*.md' ! -iname 'LICENSE*' ! -iname '*.yml' | head -1)"; \
    install -m0755 "$bin" /out/dnscollector

# Prometheus (static Go binary)
RUN set -eux; \
    url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    curl -fSL --retry 3 -o p.tgz "$url"; mkdir p; tar -xzf p.tgz -C p --strip-components=1; \
    install -m0755 p/prometheus /out/prometheus; install -m0755 p/promtool /out/promtool

# Loki (single-binary)
RUN set -eux; \
    url="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${TARGETARCH}.zip"; \
    curl -fSL --retry 3 -o loki.zip "$url"; unzip -o loki.zip; \
    install -m0755 "loki-linux-${TARGETARCH}" /out/loki

# Grafana (full dir — needs conf/ + public/)
RUN set -eux; \
    url="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    curl -fSL --retry 3 -o g.tgz "$url"; mkdir -p /out/grafana; \
    tar -xzf g.tgz -C /out/grafana --strip-components=1

# ---------------------------------------------------------------------------
# Stage 2: runtime — supervisord drives all four processes
# ---------------------------------------------------------------------------
FROM debian:12-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates supervisor curl tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/dnscollector /usr/local/bin/dnscollector
COPY --from=fetch /out/prometheus   /usr/local/bin/prometheus
COPY --from=fetch /out/promtool     /usr/local/bin/promtool
COPY --from=fetch /out/loki         /usr/local/bin/loki
COPY --from=fetch /out/grafana      /usr/share/grafana

# Configs (localhost wiring — all services share the container's loopback)
COPY config/dnscollector/config.yml      /etc/dnscollector/config.yml
COPY config/prometheus/prometheus.yml    /etc/prometheus/prometheus.yml
COPY config/loki/loki-config.yml         /etc/loki/loki-config.yml
COPY config/grafana/custom.ini           /etc/grafana/custom.ini
COPY config/grafana/provisioning         /etc/grafana/provisioning
COPY supervisord.conf                    /etc/supervisor/conf.d/dnstap2.conf

RUN mkdir -p /var/lib/prometheus /var/lib/grafana /var/lib/loki \
             /var/log/dnscollector /var/log/grafana /var/log/supervisor

# dnstap-in 6001 · grafana 3000 · prometheus 9090 · loki 3100 · collector metrics 9599
EXPOSE 6001 3000 9090 3100 9599

# tini reaps zombies; supervisord runs the four services in the foreground.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
