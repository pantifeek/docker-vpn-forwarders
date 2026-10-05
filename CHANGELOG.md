# Changelog

## Unreleased public repository preparation

- selected the newer IKEv2 split-DNS source;
- selected the newer OpenVPN source with TCP-forwarder supervision;
- selected the DNS-aware L2TP/IPsec source;
- retained the current WireGuard, FortiGate/openfortivpn and Kerio sources;
- converted IKEv2 and L2TP/IPsec Dockerfiles from local-image inheritance to standalone Debian builds;
- added Compose templates, security guidance, status notes and repository hygiene checks;
- intentionally excluded all live VPN profiles, secrets, certificates, customer identifiers and runtime logs.

## Unreleased — Portainer/public hardening

- Added Portainer Git Stack templates and `.env.example` files for all VPN types.
- Reworked top-level README for fast deployment and Guacamole integration.
- Added split-DNS and `socat` supervision to WireGuard, FortiGate and Kerio wrappers.
- Added `socat` supervision to L2TP/IPsec.
- Added forwarder-only recovery where practical to avoid unnecessary VPN reconnects.
- Added repeated-recovery failure exit so Docker restart policy can recover a stuck container.
- Improved Kerio fingerprint diagnostics: distinguish unreachable TCP/4090 from TLS fingerprint-detection failure.
- Added Portainer template checks to CI.
