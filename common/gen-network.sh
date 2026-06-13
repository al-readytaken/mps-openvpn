#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "Usage: $0 <name> <mode> <port> <subnet>"
  echo ""
  echo "  name    - unique network name (e.g. office-tun)"
  echo "  mode    - tun or tap"
  echo "  port    - UDP port (e.g. 1194)"
  echo "  subnet  - CIDR subnet (e.g. 10.8.0.0/24)"
  echo ""
  echo "Examples:"
  echo "  $0 office-tun tun 1194 10.8.0.0/24"
  echo "  $0 iot-tap   tap 1195 10.9.0.0/24"
  exit 1
fi

NAME="$1"
MODE="$2"
PORT="$3"
SUBNET="$4"

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
NET_DIR="$COMMON_DIR/../networks/$NAME"

source "$COMMON_DIR/download-easyrsa.sh"

if [ ! -f "$PKI_DIR/ca.crt" ]; then
  echo "[!] CA not found. Run gen-certs.sh first."
  exit 1
fi

if [ -d "$NET_DIR" ]; then
  echo "[!] Network '$NAME' already exists at $NET_DIR"
  exit 1
fi

# --- helpers ---

cidr_to_netmask() {
  local cidr=$1
  local mask=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF))
  printf "%d.%d.%d.%d" \
    $(( (mask >> 24) & 0xFF )) \
    $(( (mask >> 16) & 0xFF )) \
    $(( (mask >> 8) & 0xFF )) \
    $(( mask & 0xFF ))
}

network_base() {
  local ip=$1
  local cidr=$2
  local mask=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF))
  local ip_num=0
  local IFS=.
  for octet in $ip; do
    ip_num=$(( (ip_num << 8) | octet ))
  done
  local base=$(( ip_num & mask ))
  printf "%d.%d.%d.%d" \
    $(( (base >> 24) & 0xFF )) \
    $(( (base >> 16) & 0xFF )) \
    $(( (base >> 8) & 0xFF )) \
    $(( base & 0xFF ))
}

ip_plus_n() {
  local base_ip=$1
  local n=$2
  local ip_num=0
  local IFS=.
  for octet in $base_ip; do
    ip_num=$(( (ip_num << 8) | octet ))
  done
  local result=$(( ip_num + n ))
  printf "%d.%d.%d.%d" \
    $(( (result >> 24) & 0xFF )) \
    $(( (result >> 16) & 0xFF )) \
    $(( (result >> 8) & 0xFF )) \
    $(( result & 0xFF ))
}

# --- parse subnet ---

IFS=/ read -r NET_IP CIDR <<< "$SUBNET"
NETMASK=$(cidr_to_netmask "$CIDR")
BASE=$(network_base "$NET_IP" "$CIDR")
GATEWAY=$(ip_plus_n "$BASE" 1)
POOL_START=$(ip_plus_n "$BASE" 10)
POOL_END=$(ip_plus_n "$BASE" 100)

export EASYRSA_BATCH=1
export EASYRSA_NO_PASS=1

echo "[*] Creating network '$NAME' ($MODE, port $PORT, subnet $SUBNET) ..."

mkdir -p "$NET_DIR/ccd" "$NET_DIR/clients"

# --- copy shared CA cert ---
cp "$PKI_DIR/ca.crt" "$NET_DIR/"

# --- generate server cert ---
cd "$EASYRSA_DIR"
if [ ! -f "$PKI_DIR/issued/${NAME}.crt" ]; then
  echo "[*] Generating server certificate for '$NAME' ..."
  ./easyrsa gen-req "$NAME" nopass
  ./easyrsa sign-req server "$NAME"
else
  echo "[*] Server certificate for '$NAME' already exists, reusing."
fi
cp "$PKI_DIR/issued/${NAME}.crt" "$NET_DIR/server.crt"
cp "$PKI_DIR/private/${NAME}.key" "$NET_DIR/server.key"

# --- generate DH params ---
if [ ! -f "$PKI_DIR/dh.pem" ]; then
  echo "[*] Generating DH parameters (2048 bit) ..."
  ./easyrsa gen-dh
else
  echo "[*] DH parameters already exist, reusing."
fi
cp "$PKI_DIR/dh.pem" "$NET_DIR/"

# --- generate TLS-Auth key ---
echo "[*] Generating TLS-Auth key ..."
docker run --rm alpine:3.21 sh -c "apk add -q openvpn && openvpn --genkey secret /dev/stdout" \
  > "$NET_DIR/ta.key"

# --- create server.conf ---

if [ "$MODE" = "tun" ]; then
  SERVER_DIRECTIVE="server $BASE $NETMASK"
  MODE_BLOCK="$SERVER_DIRECTIVE
push \"route $BASE $NETMASK\""
elif [ "$MODE" = "tap" ]; then
  MODE_BLOCK="mode server
tls-server
ifconfig $GATEWAY $NETMASK
ifconfig-pool $POOL_START $POOL_END $NETMASK
push \"route-gateway $GATEWAY\""
else
  echo "[!] Unknown mode '$MODE'. Use 'tun' or 'tap'."
  exit 1
fi

cat > "$NET_DIR/server.conf" <<EOF
# OpenVPN server config for network: $NAME
dev $MODE
proto udp
port $PORT

ca /etc/openvpn/networks/$NAME/ca.crt
cert /etc/openvpn/networks/$NAME/server.crt
key /etc/openvpn/networks/$NAME/server.key
dh /etc/openvpn/networks/$NAME/dh.pem
tls-crypt /etc/openvpn/networks/$NAME/ta.key
crl-verify /etc/openvpn/networks/$NAME/crl.pem

client-config-dir /etc/openvpn/networks/$NAME/ccd
tls-verify "/etc/openvpn/networks/$NAME/verify.sh"

$MODE_BLOCK

script-security 2
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
client-to-client
duplicate-cn
status /var/log/${NAME}-status.log
log-append /var/log/${NAME}.log
verb 3
EOF

# --- copy CRL ---
if [ -f "$PKI_DIR/crl.pem" ]; then
  cp "$PKI_DIR/crl.pem" "$NET_DIR/"
else
  touch "$NET_DIR/crl.pem"
fi

# --- create verify.sh (tls-verify whitelist) ---
cat > "$NET_DIR/verify.sh" <<'EOF'
#!/bin/sh
# Only enforce CCD whitelist for the client cert (depth=0), not the CA
if [ "$depth" = "0" ]; then
  NET_DIR="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$NET_DIR/ccd/$X509_0_CN" ]
  exit $?
fi
exit 0
EOF
chmod +x "$NET_DIR/verify.sh"

echo "[+] Network '$NAME' created successfully!"
echo "    Config: $NET_DIR/server.conf"
echo "    CCD:    $NET_DIR/ccd/"
echo "    Port:   $PORT/udp, Subnet: $SUBNET"
