# MPS OpenVPN Testbed

Local OpenVPN testbed with named, individually configurable networks
(TUN/TAP), per-network client access control, and parametrized client
containers.

## Requirements

- Docker + Docker Compose
- Bash, curl

## Usage

```
# Fresh setup
bash common/gen-certs.sh
bash common/gen-network.sh example-tun tun 1194 10.8.0.0/24
bash common/gen-network.sh example-tap tap 1195 10.9.0.0/24
bash common/gen-client.sh client1 example-tun example-tap
bash common/gen-client.sh client2 example-tun example-tap
docker compose up -d --build

# Add a network later
bash common/gen-network.sh default-tap tap 1197 10.11.0.0/24
# Add port 1197 to docker-compose.yml ports, then:
docker compose up -d --build server

# Grant existing clients access to the new network
bash common/gen-client.sh client1 example-tun example-tap default-tap

# Add a client later
bash common/gen-client.sh bob example-tun
# Add bob service to docker-compose.yml, then:
docker compose up -d --build bob

# Revoke a client
bash common/revoke-client.sh bob
docker compose restart server
```

## Architecture

### Shared CA, One PKI

A single Easy-RSA PKI at `common/easy-rsa/pki/` signs all certificates
(server and client). Every network and every client draws from the same CA.

### Named Networks

Each network lives in `networks/<name>/` with its own `server.conf`,
server cert, DH params, `ta.key`, `crl.pem`, `verify.sh`, `ccd/`
directory, and per-client `.ovpn` files. Both TUN (layer 3) and TAP
(layer 2) modes are supported on separate ports and subnets.

### Per-Network Access Control (CCD Whitelist)

Access control is enforced at TLS handshake time by each network's
`verify.sh`, triggered by OpenVPN's `tls-verify` directive:

```sh
# verify.sh checks whether ccd/<CN> exists for client certs (depth=0)
if [ "$depth" = "0" ]; then
  NET_DIR="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$NET_DIR/ccd/$X509_0_CN" ]; exit $?
fi
exit 0
```

A client is allowed on a network iff
`networks/<network>/ccd/<CN>` exists. Blocked clients see
`WARNING: Failed running command (--tls-verify script): external
program exited with error status: 1` in server logs.

## Common Scripts

See `common/README.md` for the full reference on `gen-certs.sh`,
`gen-network.sh`, `gen-client.sh`, `revoke-client.sh`,
`download-easyrsa.sh`, configuration, and bare-metal usage.

## Docker Compose

The `docker-compose.yml` defines a `vpn-net` bridge network
(`172.20.0.0/24` — must not overlap with any VPN subnet).

**Server service** mounts `./networks:/etc/openvpn/networks:ro`,
exposes UDP ports matching your networks, needs `NET_ADMIN` +
`/dev/net/tun` + `net.ipv4.ip_forward=1`. `server/start.sh`
auto-discovers `networks/*/server.conf` and starts one OpenVPN
instance per network.

## Monitoring

Each network writes a status file. Check connected clients:

```
docker exec openvpn-server cat /var/log/<name>-status.log
```

For real-time OpenVPN logs:

```
docker exec openvpn-server tail -f /var/log/<name>.log
```

## Troubleshooting

- **Docker subnet overlap:** `vpn-net` (`172.20.0.0/24`) must not
  overlap with any VPN subnet. Change it in `docker-compose.yml` if
  needed.
- **TLS handshake failures:** Ensure
  `networks/<network>/ccd/<CN>` exists. If the cert is revoked, run
  `revoke-client.sh` to regenerate the CRL across all networks.
- **ta.key changes:** Each `gen-network.sh` run generates a new
  `ta.key`. Existing `.ovpn` files embed the old key — regenerate
  them with `gen-client.sh`.

## .gitignore Rules

| Pattern | Reason |
|---------|--------|
| `*.key` | All private keys |
| `common/easy-rsa/` | External software, auto-downloaded |
| `common/clients/` | Raw client certs and keys |
| `networks/` | Entire networks directory (all regeneratable) |
| `.env` | Local overrides |

Tracked in git: scripts, `docker-compose.yml`, `Dockerfile`s,
`.gitignore`, `.env.example`.
