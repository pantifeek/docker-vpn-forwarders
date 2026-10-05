# Security

## Do not commit live VPN material

Do not commit:

- usernames or passwords;
- pre-shared keys;
- WireGuard private keys;
- OpenVPN client profiles from production;
- private/client certificates and PKCS#12 files;
- production VPN gateway hostnames or IP addresses when they are considered sensitive;
- customer/internal DNS names;
- packet captures or logs containing infrastructure metadata.

Use the example Compose files only as templates.

## Reporting a vulnerability

If this repository is made public, configure a private vulnerability-reporting channel in GitHub before advertising it for production use.

## Container privileges

The examples deliberately avoid `privileged: true`. Do not add it as a generic workaround. Grant only the capabilities and devices needed by the selected VPN type.
