# Common Scripts

All scripts run natively (no Docker required) except where noted.

## Configuration

Edit `.env` in the project root to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_ADDRESS` | `server` | Hostname/IP in `.ovpn` client configs |
| `EASYRSA_REQ_COUNTRY` | `US` | CA subject country |
| `EASYRSA_REQ_PROVINCE` | `California` | CA subject province |
| `EASYRSA_REQ_CITY` | `San Francisco` | CA subject city |
| `EASYRSA_REQ_ORG` | `MPS OpenVPN Test` | CA subject org |
| `EASYRSA_REQ_EMAIL` | `admin@example.com` | CA subject email |
| `EASYRSA_REQ_OU` | `TestLab` | CA subject OU |
| `EASYRSA_KEY_SIZE` | `2048` | RSA key size |
| `EASYRSA_ALGO` | `rsa` | Key algorithm |
| `EASYRSA_CA_EXPIRE` | `3650` | CA cert expiry in days |
| `EASYRSA_CERT_EXPIRE` | `3650` | Cert expiry in days |

## Script Reference

### `download-easyrsa.sh`

Downloads Easy-RSA 3.2.2 into `common/easy-rsa/`. Idempotent — skips
if already present. Can be run standalone or sourced by other scripts.

### `gen-certs.sh`

Boots the shared PKI: initializes Easy-RSA, builds the CA, and
generates the initial CRL. Reads subject fields from `.env`. Destroys
and recreates `common/easy-rsa/pki/` each run.

### `gen-network.sh <name> <mode> <port> <subnet>`

Creates `networks/<name>/` with:

- `server.conf` (TUN or TAP template)
- Server certificate + key
- DH parameters (shared across networks after first generation)
- `ta.key` (TLS crypt, generated via Docker)
- `ca.crt` copy, `crl.pem` copy, `verify.sh`
- Empty `ccd/` and `clients/` directories

| Parameter | Description |
|-----------|-------------|
| `name` | Network name (directory name) |
| `mode` | `tun` (layer 3) or `tap` (layer 2) |
| `port` | UDP port (e.g. 1194) |
| `subnet` | CIDR subnet (e.g. `10.8.0.0/24`) |

> **ta.key note:** `gen-network.sh` uses `docker run` to generate
> `ta.key`. If Docker is unavailable, run manually after network
> creation: `openvpn --genkey secret networks/<name>/ta.key`

### `gen-client.sh <name> <network> [network ...]`

Generates a client certificate signed by the shared CA, then for each
listed network:

1. Creates a CCD whitelist marker at
   `networks/<network>/ccd/<name>`
2. Generates a self-contained `.ovpn` file at
   `networks/<network>/clients/<name>.ovpn` with inline PEMs
3. Packages the archive
   `common/clients/<name>/<name>.tar.gz` containing `.ovpn` files,
   raw certs, and `install-debian.sh`

If the client certificate already exists in the PKI, it is reused.

### `revoke-client.sh <name>`

Revokes a client certificate, regenerates the CRL, and copies it into
every network directory. After revocation, restart the server:
`docker compose restart server`.

## Bare-Metal Usage

### Prerequisites

```
apk add openvpn            # Alpine
apt install openvpn         # Debian/Ubuntu
dnf install openvpn         # Fedora/RHEL
```

### Start server per network

```
for conf in networks/*/server.conf; do
  sudo openvpn --config "$conf" --daemon
done
```

### Start client per network

```
sudo openvpn --config networks/<network>/clients/<name>.ovpn --daemon
```

### Firewall

```
iptables -A INPUT -p udp --dport 1194 -j ACCEPT
iptables -A INPUT -p udp --dport 1195 -j ACCEPT
```

### Stop

```
sudo killall openvpn
```
