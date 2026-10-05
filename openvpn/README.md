# OpenVPN forwarder

OpenVPN client plus supervised `socat` TCP forwarders.

The selected implementation verifies:

- the OpenVPN process is alive;
- a TUN/TAP interface has an IPv4 address;
- each forwarding listener is still running/listening;
- a health target is routed through the VPN interface;
- the target TCP port is reachable.

If only a `socat` forwarder fails, it is restarted without unnecessarily restarting the VPN session.

## Profile

Mount the client profile read-only at `/config/client.ovpn` or change `OVPN_CONFIG_FILE`.

The current implementation also expects a private-key passphrase file (`OVPN_KEY_PASSWORD_FILE`, default `/run/secrets/key_password`). The `.ovpn` profile itself must not require an interactive prompt for any other credentials.

Do not commit a production `.ovpn` file to the repository.
