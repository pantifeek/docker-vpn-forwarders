FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        openvpn \
        iproute2 \
        netcat-openbsd \
        socat \
        procps \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p \
        /run/openvpn-forwarder \
        /run/openvpn \
        /var/log

COPY entrypoint.sh /usr/local/bin/openvpn-forwarder

RUN chmod 0755 /usr/local/bin/openvpn-forwarder

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD test -f /run/openvpn-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/openvpn-forwarder"]
