FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openfortivpn \
        ppp \
        iproute2 \
        netcat-openbsd \
        socat \
        procps \
        ca-certificates \
        bind9-dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/fortivpn-forwarder /run/openfortivpn

COPY entrypoint.sh /usr/local/bin/fortivpn-forwarder

RUN chmod 0755 /usr/local/bin/fortivpn-forwarder

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD test -f /run/fortivpn-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/fortivpn-forwarder"]
