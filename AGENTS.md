# Agent Guide — MPS OpenVPN

## Project Overview

Local OpenVPN testbed for testing TUN/TAP networks with per-network access control. Uses Docker Compose for orchestration but scripts work bare-metal.

## Key Decisions & Conventions

### Shared CA (Single PKI)
- **Decision:** One CA signs all certificates (server and client). No per-network CA.
- **Rationale:** Simpler management. Revocation applies globally.
- **Location:** `common/easy-rsa/pki/` (gitignored, auto-downloaded by `download-easyrsa.sh`)
- **Impact:** All certs share the same `ca.crt`. All servers trust all client certs at the TLS level; access control is handled separately by CCD whitelist.

### Access Control via CCD Whitelist (NOT per-network CA)
- **Decision:** `tls-verify` + `verify.sh` checks for `ccd/<CN>` file presence.
- **Rationale:** Reuses existing `ccd/` directory that OpenVPN already supports. No separate management files needed.
- **Enforcement:** Only at `depth=0` (client cert). CA cert at `depth=1` is skipped.
- **Blocked client log:** `WARNING: Failed running command (--tls-verify script): external program exited with error status: 1`
- **Allowed client log:** `VERIFY SCRIPT OK`

### tls-crypt (NOT tls-auth)
- **Decision:** Use `tls-crypt` instead of `tls-auth`.
- **Rationale:** Encrypts + authenticates TLS channel. No `key-direction` directive needed. Simpler client config.
- **Impact:** `ta.key` is used with `tls-crypt` directive, not `tls-auth`. `.ovpn` files use `<tls-crypt>` block.

### Network Naming & Layout
- **Convention:** Each network is a directory under `networks/<name>/`. Names are arbitrary but should match the CN of the server cert.
- **Ports:** Assigned manually (no auto-allocation). Passed as parameter to `gen-network.sh`.
- **Subnets:** Must not overlap with Docker `vpn-net` (172.20.0.0/24) or each other.
- **Mode:** TUN (layer 3, routed) or TAP (layer 2, bridged). TAP uses `ifconfig`/`ifconfig-pool` instead of `server` directive.

### Docker Compose Pattern
- **Server:** Single `server` service. `start.sh` auto-discovers `networks/*/server.conf` and starts one OpenVPN per network.
- **Clients:** One service per client. Env vars `CLIENT_NAME` and `NETWORKS` (comma-separated). `start.sh` connects to each listed network using `networks/<network>/clients/<CLIENT_NAME>.ovpn`.
- **vpn-net subnet:** 172.20.0.0/24 — must NOT overlap with any VPN subnet.
- **Static IPs:** Each container gets a static IP on `vpn-net` for reliable connectivity.

### Port Ranges
- `docker-compose.yml` exposes `1194-1195:1194-1195/udp`. Extend the range as networks are added.

## File Layout

```
.gitignore              — ignores *.key, common/easy-rsa/, common/clients/, networks/
AGENTS.md               — this file
README.md               — full user documentation
docker-compose.yml      — server + client services
setup.sh                — full automated setup (example template, may be out of date)
server/
  Dockerfile            — Alpine + openvpn + iptables + bash
  start.sh              — scans networks/*/server.conf, starts all
client/
  Dockerfile            — Alpine + openvpn + bash
  start.sh              — reads CLIENT_NAME + NETWORKS env, starts connections
common/
  vars                  — Easy-RSA subject fields (edit before gen-certs.sh)
  download-easyrsa.sh   — idempotent, standalone or sourced by other scripts
  gen-certs.sh          — bootstrap CA + CRL (destroys & recreates pki/)
  gen-network.sh        — create network dir + server.conf + certs + keys
  gen-client.sh         — create client cert + .ovpn + CCD marker per network
  revoke-client.sh      — revoke cert, regenerate CRL, push to all networks
  easy-rsa/             — (gitignored, auto-downloaded)
  clients/              — (gitignored)
networks/               — (gitignored, regeneratable)
```

## Script Behavior

### download-easyrsa.sh
- Uses `BASH_SOURCE[0]` (NOT `$0`) so it works both when sourced and run standalone.
- Detects sourced mode via `(return 0 2>/dev/null)` pattern to use `return` vs `exit`.
- Version pinned to Easy-RSA 3.2.2.

### gen-certs.sh
- Sources `download-easyrsa.sh` first.
- ALWAYS destroys and recreates `pki/` — **not idempotent**.
- Run once per project or when you want a fresh CA.

### gen-network.sh
- Sources `download-easyrsa.sh` first (idempotent).
- Uses `docker run --rm alpine:3.21 openvpn --genkey secret` to generate `ta.key`. This means it requires Docker unless you manually generate ta.key.
- DH params are shared: generated once, copied to each network.
- Server cert CN = network name. If cert already exists in PKI, it's reused.
- Errors out if network directory already exists.

### gen-client.sh
- Sources `download-easyrsa.sh` first (idempotent).
- If client cert already exists in PKI, it's reused (use `gen-req` + `sign-req` only if missing).
- Creates CCD marker (`networks/<network>/ccd/<CN>`) as a side effect if it doesn't exist.
- Copies raw cert/key/ca.crt to `common/clients/<name>/`.
- Generates inline `.ovpn` with embedded PEMs (cert, key, ca, tls-crypt).

### revoke-client.sh
- Sources `download-easyrsa.sh` first (idempotent).
- Does NOT clean up `ccd/` markers or `common/clients/` dir.
- Does NOT clean up `.ovpn` files.
- After revocation, server must be restarted to pick up new CRL.

## Client Access Flow

1. `gen-client.sh bob example-tun` → creates `networks/example-tun/ccd/bob`
2. bob's OpenVPN connects to example-tun server
3. Server's `tls-verify` triggers `verify.sh` at TLS handshake
4. `verify.sh` checks: `depth=0` (client cert) AND `ccd/bob` exists → ALLOW
5. If `ccd/bob` is missing or client is revoked → DENY

## Common Gotchas

- **`exit` in sourced script kills caller:** `download-easyrsa.sh` uses `return`/`exit` based on sourced detection. If editing, maintain this pattern.
- **`gen-network.sh` recreates `ta.key` each run:** Existing `.ovpn` files embed the old `ta.key`. Re-run `gen-client.sh` to regenerate `.ovpn` files after network creation.
- **`gen-certs.sh` destroys PKI:** All existing server and client certs become invalid. Must regenerate all networks and clients.
- **Docker subnet overlap:** `vpn-net` (172.20.0.0/24) must not overlap with any VPN subnet. If it does, change the Docker subnet in `docker-compose.yml`.
- **CCD enforcement at TLS level:** This is handshake-time only. It does NOT prevent a client from connecting to the same server on a different port (different network). Each network is its own OpenVPN process.
- **`--tls-verify` script security:** Verified cert fields appear as env vars (`X509_0_CN`, `X509_0_OU`, etc.). Only `depth=0` is the end-entity cert; `depth` increases for each CA in the chain.
- **Port clashes:** If running multiple projects or real OpenVPN instances, adjust port assignments.

## Common Workflows

### Fresh from scratch
```bash
docker compose down --remove-orphans
rm -rf networks/* common/clients/* common/easy-rsa/pki
bash common/gen-certs.sh
bash common/gen-network.sh <name> <mode> <port> <subnet>
bash common/gen-client.sh <client> <network> [network...]
# update docker-compose.yml
docker compose up -d --build
```

### Add client to existing network
```bash
bash common/gen-client.sh newguy example-tun
# add newguy service to docker-compose.yml
docker compose up -d --build newguy
```

### Revoke client
```bash
bash common/revoke-client.sh newguy
docker compose restart server
```

## gitignore Strategy

Everything sensitive or regeneratable is ignored:
- `*.key` — all private keys anywhere
- `common/easy-rsa/` — external software, auto-downloaded by `download-easyrsa.sh`
- `common/clients/` — raw certs/keys copied from PKI
- `networks/` — configs, certs, keys, membership markers, .ovpn files

Tracked: scripts, `docker-compose.yml`, `Dockerfile`s, `setup.sh`, `.gitignore`, `AGENTS.md`.
