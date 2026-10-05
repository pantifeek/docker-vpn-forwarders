FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        strongswan \
        strongswan-charon \
        strongswan-starter \
        libcharon-extauth-plugins \
        libcharon-extra-plugins \
        libstrongswan-standard-plugins \
        xl2tpd \
        ppp \
        kmod \
        iproute2 \
        netcat-openbsd \
        socat \
        procps \
        ca-certificates \
        bind9-dnsutils \
    && mkdir -p \
        /run/xl2tpd \
        /run/l2tp-ipsec-forwarder \
        /var/log \
    && touch /run/xl2tpd/l2tp-control \
    && touch /var/log/xl2tpd.log \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/l2tp-ipsec-forwarder

RUN chmod 0755 /usr/local/bin/l2tp-ipsec-forwarder

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD test -f /run/l2tp-ipsec-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/l2tp-ipsec-forwarder"]
