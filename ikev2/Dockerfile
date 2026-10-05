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
        iproute2 \
        netcat-openbsd \
        socat \
        procps \
        ca-certificates \
        bind9-dnsutils \
    && update-ca-certificates \
    && mkdir -p \
        /etc/ipsec.d/cacerts \
        /config/ca \
        /run/ikev2-forwarder \
        /var/log \
    && find /usr/share/ca-certificates/mozilla \
        -type f \
        -name '*.crt' \
        -exec cp {} /etc/ipsec.d/cacerts/ \; \
    && rm -f /sbin/resolvconf /usr/sbin/resolvconf \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/ikev2-forwarder

RUN chmod 0755 /usr/local/bin/ikev2-forwarder

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD test -f /run/ikev2-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/ikev2-forwarder"]
