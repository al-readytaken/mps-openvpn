# MPS OpenVPN Testbed

Local OpenVPN testbed with named, individually configurable networks (TUN/TAP), per-network client access control, and parametrized client containers.

## Requirements

- Docker + Docker Compose
- Bash, curl

## Quick Start

```bash
# 1. Bootstrap the shared Certificate Authority
bash common/gen-certs.sh

# 2. Create networks (name, mode, port, subnet)
bash common/gen-network.sh example-tun tun 1194 10.8.0.0/24
bash common/gen-network.sh example-tap tap 1195 10.9.0.0/24

# 3. Create clients (name, network...)
bash common/gen-client.sh client1 example-tun example-tap
bash common/gen-client.sh client2 example-tun example-tap
bash common/gen-client.sh client3 example-tun example-tap

# 4. Update docker-compose.yml with client services, then start
docker compose up -d --build
```

## Full Example

Fresh setup from scratch:

```bash
docker compose down --remove-orphans
rm -rf networks/* common/clients/* common/easy-rsa/pki

bash common/gen-certs.sh
bash common/gen-network.sh example-tun tun 1194 10.8.0.0/24
bash common/gen-network.sh example-tap tap 1195 10.9.0.0/24
bash common/gen-client.sh client1 example-tun example-tap
bash common/gen-client.sh client2 example-tun example-tap
bash common/gen-client.sh client3 example-tun example-tap
# edit docker-compose.yml with client1/2/3 services
docker compose up -d --build
```

## Architecture

### Shared CA, One PKI

A single Easy-RSA PKI at `common/easy-rsa/pki/` signs all certificates (server and client). Every network and every client draws from the same CA. This avoids managing multiple CAs.

### Named Networks

Each network lives in `networks/<name>/` with its own `server.conf`, server cert, DH params, `ta.key`, `crl.pem`, `verify.sh`, `ccd/` directory, and per-client `.ovpn` files.

Both TUN (layer 3) and TAP (layer 2) modes are supported on separate ports and subnets.

### Per-Network Access Control (CCD Whitelist)

Access control is enforced at TLS handshake time by each network's `verify.sh` script, triggered by OpenVPN's `tls-verify` directive:

```
tls-verify "/etc/openvpn/networks/<name>/verify.sh"
```

`verify.sh` checks whether a file named after the client's Common Name exists in `ccd/`:

```sh
if [ "$depth" = "0" ]; then
  NET_DIR="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$NET_DIR/ccd/$X509_0_CN" ]
  exit $?
fi
exit 0
```

A client is allowed on a network **iff** `networks/<network>/ccd/<CN>` exists.

### Parametrized Client Containers

Client containers read `CLIENT_NAME` and `NETWORKS` environment variables. The `start.sh` script picks the corresponding `.ovpn` file for each listed network from `networks/<network>/clients/<CLIENT_NAME>.ovpn`.

## Directory Structure

```
.
├── client/                          # Docker client image
│   ├── Dockerfile
│   └── start.sh                     # Reads CLIENT_NAME + NETWORKS env vars
├── server/                          # Docker server image
│   ├── Dockerfile
│   └── start.sh                     # Auto-discovers networks/*/server.conf
├── common/
│   ├── download-easyrsa.sh          # Downloads Easy-RSA (idempotent, standalone or sourced)
│   ├── vars                         # CA certificate subject fields
│   ├── gen-certs.sh                 # Bootstrap the shared CA + initial CRL
│   ├── gen-network.sh               # Create a named network (server.conf, certs, keys)
│   ├── gen-client.sh                # Create a client cert + .ovpn + CCD whitelist
│   ├── revoke-client.sh             # Revoke a client cert, regenerate CRL
│   ├── clients/                     # Raw client certs and keys (gitignored)
│   └── easy-rsa/                    # Easy-RSA framework (gitignored, auto-downloaded)
├── networks/                        # Networks directory (gitignored, regeneratable)
├── docker-compose.yml               # Server + client services
├── setup.sh                         # Full automated setup (templates)
└── .gitignore
```

## Vars Configuration

Edit `common/vars` to customize CA certificate subject fields:

```bash
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "California"
set_var EASYRSA_REQ_CITY       "San Francisco"
set_var EASYRSA_REQ_ORG        "MPS OpenVPN Test"
set_var EASYRSA_REQ_EMAIL      "admin@example.com"
set_var EASYRSA_REQ_OU         "TestLab"
set_var EASYRSA_KEY_SIZE        2048
set_var EASYRSA_ALGO            rsa
set_var EASYRSA_CA_EXPIRE       3650
set_var EASYRSA_CERT_EXPIRE     3650
```

## Scripts Reference

### `common/download-easyrsa.sh`

Downloads Easy-RSA 3.2.2 into `common/easy-rsa/`. Idempotent — skips if already present. Can be run standalone or sourced by other scripts.

### `common/gen-certs.sh`

Boots the shared PKI: initializes Easy-RSA, builds the CA, generates initial CRL, and copies `common/vars` into the easy-rsa dir. Destroys and recreates `common/easy-rsa/pki/` each run.

### `common/gen-network.sh <name> <mode> <port> <subnet>`

Creates `networks/<name>/` with:
- `server.conf` (TUN or TAP template)
- Server certificate + key
- DH parameters (shared across networks after first generation)
- `ta.key` (TLS crypt)
- `ca.crt` copy
- `crl.pem` copy
- `verify.sh`
- Empty `ccd/` and `clients/` directories

| Parameter | Description |
|-----------|-------------|
| `name`    | Network name (directory name) |
| `mode`    | `tun` (layer 3) or `tap` (layer 2) |
| `port`    | UDP port (e.g. 1194) |
| `subnet`  | CIDR subnet (e.g. `10.8.0.0/24`) |

### `common/gen-client.sh <name> <network> [network ...]`

Generates a client certificate signed by the shared CA, then for each listed network:
1. Creates a CCD whitelist marker at `networks/<network>/ccd/<name>`
2. Generates a self-contained `.ovpn` file at `networks/<network>/clients/<name>.ovpn` with inline PEMs (cert, key, CA, tls-crypt)

If the client certificate already exists in the PKI, it is reused.

### `common/revoke-client.sh <name>`

Revokes a client certificate, regenerates the CRL, and copies it into every network directory. After revocation, restart the server: `docker compose restart server`.

## gitignore Rules

| Pattern | Reason |
|---------|--------|
| `*.key` | All private keys |
| `common/easy-rsa/` | External software, auto-downloaded |
| `common/clients/` | Raw client certs and keys |
| `networks/` | Entire networks directory (configs, certs, keys, membership — all regeneratable) |

Tracked in git: scripts (`gen-*.sh`, `revoke-client.sh`, `download-easyrsa.sh`), `docker-compose.yml`, `setup.sh`, `Dockerfile`s.

## Docker Compose

The `docker-compose.yml` defines a `vpn-net` bridge network (`172.20.0.0/24` — must not overlap with any VPN subnet).

### Server Service

- Mounts `./networks:/etc/openvpn/networks:ro`
- Exposes the port range matching your networks
- Needs `NET_ADMIN` + `/dev/net/tun` + `net.ipv4.ip_forward=1`
- `start.sh` discovers `networks/*/server.conf` and starts one OpenVPN instance per network

### Client Services

Each client needs:
- Env `CLIENT_NAME`: must match a client certificate CN
- Env `NETWORKS`: comma-separated list of networks to join
- Mounts `./networks:/etc/openvpn/networks:ro`
- Depends on the server service
- Unique static IP on `vpn-net`

Add new clients by copying an existing client service block and changing the name and IP.

## Adding a Network

```bash
bash common/gen-network.sh iot-tap tap 1197 10.11.0.0/24
# Add port 1197 to server ports in docker-compose.yml
docker compose up -d --build server
```

Then grant access to existing clients:
```bash
bash common/gen-client.sh client1 example-tun example-tap iot-tap
# Update NETWORKS in docker-compose.yml for client1
docker compose up -d client1
```

## Adding a Client

```bash
bash common/gen-client.sh bob example-tun
# Add a bob service to docker-compose.yml
docker compose up -d --build bob
```

## Revoking a Client

```bash
bash common/revoke-client.sh bob
docker compose restart server
# bob can no longer connect to any network
```

## How Access Control Works

| Step | What happens |
|------|-------------|
| `gen-client.sh bob example-tun` | Creates `networks/example-tun/ccd/bob` (whitelist marker) |
| bob connects to example-tun | OpenVPN triggers `tls-verify` → `verify.sh` |
| `verify.sh` checks `$depth` | Only enforces for client certs (`depth=0`) |
| Checks `ccd/$X509_0_CN` | If `ccd/bob` exists → success; otherwise → rejection |
| bob tries example-tap | No `ccd/bob` in `networks/example-tap/ccd/` → blocked |

TLS handshake logs show `VERIFY SCRIPT OK` for allowed clients, and `WARNING: Failed running command (--tls-verify script): external program exited with error status: 1` for blocked ones.

## Troubleshooting

**docker compose network conflicts** — The `vpn-net` subnet (`172.20.0.0/24`) must not overlap with any VPN subnet. Change it in `docker-compose.yml` if needed.

**TLS handshake failures** — Check the server logs. If a client is blocked, ensure `networks/<network>/ccd/<CN>` exists. If cert is revoked, run `revoke-client.sh` which regenerates the CRL across all networks.

**ta.key changes** — Each run of `gen-network.sh` generates a new `ta.key`. Existing `.ovpn` files will have the old key and must be regenerated with `gen-client.sh`.
