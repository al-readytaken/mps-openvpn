# Agent Guide — MPS OpenVPN

## Project Overview

Local OpenVPN testbed for testing TUN/TAP networks with per-network
access control. Uses Docker Compose for orchestration but scripts work
bare-metal.

## Key Decisions & Conventions

### Shared CA (Single PKI)
- **Decision:** One CA signs all certificates (server and client). No
  per-network CA.
- **Rationale:** Simpler management. Revocation applies globally.
- **Location:** `common/easy-rsa/pki/` (gitignored, auto-downloaded by
  `download-easyrsa.sh`)
- **Impact:** All certs share the same `ca.crt`. All servers trust all
  client certs at the TLS level; access control is handled separately by
  CCD whitelist.

### Access Control via CCD Whitelist (NOT per-network CA)
- **Decision:** `tls-verify` + `verify.sh` checks for `ccd/<CN>` file
  presence.
- **Rationale:** Reuses existing `ccd/` directory that OpenVPN already
  supports. No separate management files needed.
- **Enforcement:** Only at `depth=0` (client cert). CA cert at `depth=1`
  is skipped.
- **Blocked client log:** `WARNING: Failed running command (--tls-verify
  script): external program exited with error status: 1`
- **Allowed client log:** `VERIFY SCRIPT OK`
- **verify.sh also logs:** `verify.sh: <CN> from <IP> connecting`

### tls-crypt (NOT tls-auth)
- **Decision:** Use `tls-crypt` instead of `tls-auth`.
- **Rationale:** Encrypts + authenticates TLS channel. No `key-direction`
  directive needed. Simpler client config.
- **Impact:** `ta.key` is used with `tls-crypt` directive, not `tls-auth`.
  `.ovpn` files use `<tls-crypt>` block.

### Network Naming & Layout
- **Convention:** Each network is a directory under `networks/<name>/`.
  Names are arbitrary but should match the CN of the server cert.
- **Ports:** Assigned manually (no auto-allocation). Passed as parameter
  to `gen-network.sh`.
- **Subnets:** Must not overlap with Docker `vpn-net` (172.20.0.0/24) or
  each other.
- **Mode:** TUN (layer 3, routed) or TAP (layer 2, bridged). TAP uses
  `ifconfig`/`ifconfig-pool` instead of `server` directive.

### Configuration via `.env` (NOT `common/vars`)
- **Decision:** All configuration is in `.env` at the project root.
  `common/vars` is removed.
- **Rationale:** Single source of truth. Docker Compose auto-loads
  `.env`. No duplicate config files.
- **Impact:** `gen-certs.sh` generates Easy-RSA `vars` file from `.env`
  values. `SERVER_ADDRESS` controls the `remote` in `.ovpn` files.

### Server-Only Docker Compose
- **Decision:** Only a `server` service is defined. Client Docker
  services have been removed.
- **Rationale:** Clients connect natively or via bare-metal OpenVPN.
  No need for client containers.
- **Impact:** `docker-compose.yml` defines `server` + `vpn-net`.
  Clients run `sudo openvpn --config networks/<n>/clients/<c>.ovpn`.

### Systemd Integration for Clients
- **Decision:** `gen-client.sh` packages an `install-debian.sh` that
  creates one `openvpn-client@<network>` systemd service per network.
- **Rationale:** Each connection can be started/stopped/restarted
  individually. Standard Debian `openvpn` package template.
- **Usage:** `systemctl enable --now openvpn-client@office-tun`

### Port Ranges
- `docker-compose.yml` exposes `1194-1195:1194-1195/udp`. Extend the
  range as networks are added.

## File Layout

```
.gitignore              — ignores *.key, .env, common/easy-rsa/,
                          common/clients/, networks/
AGENTS.md               — this file
README.md               — condensed user docs
common/README.md        — script reference & bare-metal docs
.env.example            — tracked config template
.env                    — (gitignored) local overrides
docker-compose.yml      — server service only
setup-example.sh        — example: CA + 3 networks
server/
  Dockerfile            — Alpine + openvpn + iptables + bash
  start.sh              — scans networks/*/server.conf, starts all
client/
  Dockerfile            — (kept for reference, not used by compose)
  start.sh              — reads CLIENT_NAME + NETWORKS env
common/
  README.md             — script docs extracted from top-level README
  .env                  — (ignored) copied to project root by setup
  download-easyrsa.sh   — idempotent, standalone or sourced
  gen-certs.sh          — bootstrap CA + CRL (destroys & recreates
                          pki/), reads subject fields from .env
  gen-network.sh        — create network dir + server.conf +
                          certs + keys
  gen-client.sh         — create client cert + .ovpn + CCD
                          marker + client archive (.tar.gz)
  revoke-client.sh      — revoke cert, regenerate CRL, push to
                          all networks
  easy-rsa/             — (gitignored, auto-downloaded)
  clients/              — (gitignored) raw certs + .tar.gz archives
networks/               — (gitignored, regeneratable)
```

## Script Behavior

### Style conventions
- All scripts use `set -euo pipefail`
- Guard clauses use `if ...; then ...; exit 1; fi` (NOT
  `[ cond ] && { exit; }` — the latter causes `set -e` exits when
  condition is false)
- Loops/functions that conditionally skip use `if` statements, not
  `&&` chains
- `local` variable declarations are split across lines when one
  references another (avoids `set -u` errors)
- Minimal echo, no fancy prefixes (`[*]`, `[+]`, etc.)
- No `bash` prefix when calling other scripts

### download-easyrsa.sh
- Uses `BASH_SOURCE[0]` (NOT `$0`) so it works both when sourced
  and run standalone.
- Detects sourced mode via `(return 0 2>/dev/null)` pattern to use
  `return` vs `exit`.
- Version pinned to Easy-RSA 3.2.2.
- Logic wrapped in `download_easyrsa()` function.

### gen-certs.sh
- Sources `download-easyrsa.sh` first.
- ALWAYS destroys and recreates `pki/` — **not idempotent**.
- Reads subject fields from `.env` (falls back to defaults).
- Generates Easy-RSA `vars` file inline via `write_vars()` instead
  of copying `common/vars`.

### gen-network.sh
- Sources `download-easyrsa.sh` first (idempotent).
- Uses `docker run --rm alpine:3.21 openvpn --genkey secret` to
  generate `ta.key`. Requires Docker unless you manually generate
  ta.key.
- DH params are shared: generated once, copied to each network.
- Server cert CN = network name. If cert already exists in PKI,
  it's reused.
- Errors out if network directory already exists.
- `verify.sh` logs: `verify.sh: <CN> from <IP> connecting`
- Helper functions: `cidr_to_netmask`, `network_base`, `ip_plus_n`,
  `parse_subnet`, `ensure_server_cert`, `ensure_dh_params`,
  `generate_ta_key`, `make_mode_block`, `write_server_conf`,
  `write_verify_script`.

### gen-client.sh
- Sources `download-easyrsa.sh` first (idempotent).
- If client cert already exists in PKI, it's reused (uses `gen-req`
  + `sign-req` only if missing).
- Creates CCD marker (`networks/<network>/ccd/<CN>`) as a side
  effect if it doesn't exist.
- Copies raw cert/key/ca.crt to `common/clients/<name>/`.
- Generates inline `.ovpn` with embedded PEMs (cert, key, ca,
  tls-crypt).
- Creates client archive at `common/clients/<name>/<name>.tar.gz`
  containing:
  - `<network>.ovpn` (one per network)
  - `certs/<ca.crt>`, `certs/<name>.crt`, `certs/<name>.key`
  - `install-debian.sh` — installs packages + systemd services
    per network via `openvpn-client@<network>` template
- Reads `SERVER_ADDRESS` from `.env` for the `remote` directive.
- Functions: `load_env`, `ensure_client_cert`, `copy_client_certs`,
  `write_ccd_marker`, `write_ovpn`, `setup_client_for_network`.

### revoke-client.sh
- Sources `download-easyrsa.sh` first (idempotent).
- Does NOT clean up `ccd/` markers or `common/clients/` dir.
- Does NOT clean up `.ovpn` files.
- After revocation, server must be restarted to pick up new CRL.
- Functions: `revoke_and_update_crl`, `push_crl`.

## Client Access Flow

1. `gen-client.sh bob example-tun` →
   creates `networks/example-tun/ccd/bob`
2. bob's OpenVPN connects to example-tun server
3. Server's `tls-verify` triggers `verify.sh` at TLS handshake
4. `verify.sh` logs: `verify.sh: bob from <IP> connecting`
5. `verify.sh` checks: `depth=0` (client cert) AND
   `ccd/bob` exists → ALLOW
6. If `ccd/bob` is missing or client is revoked → DENY

## Client Archive Install Flow

1. Extract `common/clients/<name>/<name>.tar.gz`
2. Run `sudo bash install-debian.sh`
3. Script installs `openvpn` packages
4. Copies each `<network>.ovpn` to `/etc/openvpn/client/<network>.conf`
5. Enables and starts `openvpn-client@<network>` service per network
6. Manage individually: `systemctl {status|restart|stop}
   openvpn-client@<network>`

## Monitoring Connected Clients

Each network writes a status file:
```
docker exec openvpn-server cat /var/log/<name>-status.log
```

For real-time OpenVPN logs:
```
docker exec openvpn-server tail -f /var/log/<name>.log
```

Connection attempts appear as:
```
verify.sh: bob from 10.8.0.2 connecting
```

## Common Gotchas

- **`exit` in sourced script kills caller:**
  `download-easyrsa.sh` uses `return`/`exit` based on sourced
  detection. If editing, maintain this pattern.
- **`gen-network.sh` recreates `ta.key` each run:** Existing `.ovpn`
  files embed the old `ta.key`. Re-run `gen-client.sh` to
  regenerate `.ovpn` files after network creation.
- **`gen-certs.sh` destroys PKI:** All existing server and client
  certs become invalid. Must regenerate all networks and clients.
- **Docker subnet overlap:** `vpn-net` (172.20.0.0/24) must not
  overlap with any VPN subnet. If it does, change the Docker subnet
  in `docker-compose.yml`.
- **CCD enforcement at TLS level:** This is handshake-time only. It
  does NOT prevent a client from connecting to the same server on a
  different port (different network). Each network is its own
  OpenVPN process.
- **`--tls-verify` script security:** Verified cert fields appear as
  env vars (`X509_0_CN`, `X509_0_OU`, etc.). Only `depth=0` is the
  end-entity cert; `depth` increases for each CA in the chain.
- **`set -e` + `[ cond ] && action` pattern:** Using `&&` after a
  `[` condition that returns false (exit 1) causes `set -e` to kill
  the script. Always use `if cond; then action; fi`.
- **`local` variable ordering:** When one `local` var references
  another on the same line, the referenced var may not be assigned
  yet under `set -u`. Split across lines.
- **Port clashes:** If running multiple projects or real OpenVPN
  instances, adjust port assignments.
- **Client archive location:** `common/clients/<name>/<name>.tar.gz`

## Common Workflows

### Fresh from scratch
```bash
docker compose down --remove-orphans
rm -rf networks/* common/clients/* common/easy-rsa/pki
bash common/gen-certs.sh
bash common/gen-network.sh <name> <mode> <port> <subnet>
bash common/gen-client.sh <client> <network> [network...]
docker compose up -d --build

# Distribute archive to client:
# common/clients/<client>/<client>.tar.gz
```

### Add client to existing network
```bash
bash common/gen-client.sh newguy example-tun
```

### Revoke client
```bash
bash common/revoke-client.sh newguy
docker compose restart server
```

## gitignore Strategy

| Pattern | Reason |
|---------|--------|
| `*.key` | All private keys anywhere |
| `common/easy-rsa/` | External software, auto-downloaded |
| `common/clients/` | Raw certs, keys, client archives |
| `networks/` | Configs, certs, keys, membership, .ovpn |
| `.env` | Local overrides |

Tracked: scripts, `docker-compose.yml`, `Dockerfile`s,
`.gitignore`, `.env.example`, `AGENTS.md`.
