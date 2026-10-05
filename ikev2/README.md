# IKEv2 forwarder

strongSwan IKEv2 client using EAP-MSCHAPv2 authentication, with TCP forwarding through `socat`.

## Required settings

- `VPN_SERVER` — public VPN gateway hostname/IP.
- `VPN_SERVER_ID` — expected IKE server identity.
- `VPN_USERNAME` or `VPN_USERNAME_FILE`.
- `VPN_PASSWORD` or `VPN_PASSWORD_FILE`.
- `PORT_FORWARDS`.

For public repositories, prefer the `*_FILE` variants and Compose secrets.

## Traffic selectors

If all forwarding targets are literal IPv4 addresses, the script can derive `/32` selectors automatically. If a forwarding target is a DNS name, set `VPN_REMOTE_TS` explicitly, for example:

```text
VPN_REMOTE_TS=10.20.30.0/24
```

The selector must also cover a private DNS server when that DNS server is queried through the IPsec tunnel.

## Split DNS

The implementation preserves Docker's resolver for the public VPN gateway and stores DNS learned by the strongSwan resolve plugin in a separate runtime file.

Optional overrides:

```text
VPN_DNS_SERVERS=10.20.30.53,10.20.30.54
VPN_DNS_SUFFIX=corp.example
```

## Optional proposals

`VPN_IKE` and `VPN_ESP` can override strongSwan proposals when a gateway requires explicit compatibility settings. Do not enable legacy algorithms unless the remote gateway actually requires them.

## Linux capabilities

The example uses `NET_ADMIN` and `NET_RAW`. It does not require `/dev/net/tun` because IPsec is handled by the kernel XFRM/IPsec stack rather than a TUN interface.
