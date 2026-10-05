FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

ARG KERIO_DEB_URL=https://cdn.kerio.com/dwn/control/control-9.5.0-9017/kerio-control-vpnclient-9.5.0-9017-p3-linux-amd64.deb

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        openssl \
        debconf \
        iproute2 \
        procps \
        psmisc \
        netcat-openbsd \
        socat \
        bind9-dnsutils \
    && curl -fL "${KERIO_DEB_URL}" -o /tmp/kerio.deb \
    && dpkg --unpack /tmp/kerio.deb \
    && rm -f /var/lib/dpkg/info/kerio-control-vpnclient.postinst \
    && apt-get install -f -y \
    && rm -f /tmp/kerio.deb \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p \
        /run/kerio-forwarder \
        /var/log/kerio-kvc

COPY entrypoint.sh /usr/local/bin/kerio-forwarder

RUN chmod 0755 /usr/local/bin/kerio-forwarder

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=60s \
    --retries=3 \
    CMD test -f /run/kerio-forwarder/healthy || exit 1

ENTRYPOINT ["/usr/local/bin/kerio-forwarder"]
