FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        wireguard-tools \
        iproute2 \
        iptables \
        netcat-openbsd \
        socat \
        procps \
        ca-certificates \
        bind9-dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p \
        /run/wireguard-forwarder \
        /run/wireguard \
        /var/log

COPY entrypoint.sh /usr/local/bin/wireguard-forwarder

RUN chmod 0755 /usr/local/bin/wireguard-forwarder

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=45s \
    --retries=3 \
    CMD test -f /run/wireguard-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/wireguard-forwarder"]
