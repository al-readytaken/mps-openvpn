#!/usr/bin/env bash
set -euo pipefail

cidr_to_netmask() {
  local cidr=$1 mask=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF))
  printf "%d.%d.%d.%d" $(( (mask >> 24) & 0xFF )) $(( (mask >> 16) & 0xFF )) $(( (mask >> 8) & 0xFF )) $(( mask & 0xFF ))
}

network_base() {
  local ip=$1 cidr=$2 mask=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF)) ip_num=0
  local IFS=.; for octet in $ip; do ip_num=$(( (ip_num << 8) | octet )); done
  local base=$(( ip_num & mask ))
  printf "%d.%d.%d.%d" $(( (base >> 24) & 0xFF )) $(( (base >> 16) & 0xFF )) $(( (base >> 8) & 0xFF )) $(( base & 0xFF ))
}

ip_plus_n() {
  local base_ip=$1 n=$2 ip_num=0
  local IFS=.; for octet in $base_ip; do ip_num=$(( (ip_num << 8) | octet )); done
  local result=$(( ip_num + n ))
  printf "%d.%d.%d.%d" $(( (result >> 24) & 0xFF )) $(( (result >> 16) & 0xFF )) $(( (result >> 8) & 0xFF )) $(( result & 0xFF ))
}

parse_subnet() {
  local SUBNET="$1"
  IFS=/ read -r NET_IP CIDR <<< "$SUBNET"
  NETMASK=$(cidr_to_netmask "$CIDR")
  BASE=$(network_base "$NET_IP" "$CIDR")
  GATEWAY=$(ip_plus_n "$BASE" 1)
  POOL_START=$(ip_plus_n "$BASE" 10)
  POOL_END=$(ip_plus_n "$BASE" 100)
}

ensure_server_cert() {
  local EASYRSA_DIR="$1" PKI_DIR="$2" NAME="$3"
  cd "$EASYRSA_DIR"
  if [ ! -f "$PKI_DIR/issued/${NAME}.crt" ]; then
    ./easyrsa gen-req "$NAME" nopass && ./easyrsa sign-req server "$NAME"
  fi
}

ensure_dh_params() {
  local EASYRSA_DIR="$1" PKI_DIR="$2"
  cd "$EASYRSA_DIR"
  [ ! -f "$PKI_DIR/dh.pem" ] && ./easyrsa gen-dh
}

generate_ta_key() {
  local NET_DIR="$1"
  docker run --rm alpine:3.21 sh -c "apk add -q openvpn && openvpn --genkey secret /dev/stdout" > "$NET_DIR/ta.key"
}

make_mode_block() {
  local MODE="$1" BASE="$2" NETMASK="$3" GATEWAY="$4" POOL_START="$5" POOL_END="$6"
  if [ "$MODE" = "tun" ]; then
    MODE_BLOCK="server $BASE $NETMASK
push \"route $BASE $NETMASK\""
  elif [ "$MODE" = "tap" ]; then
    MODE_BLOCK="mode server
tls-server
ifconfig $GATEWAY $NETMASK
ifconfig-pool $POOL_START $POOL_END $NETMASK
push \"route-gateway $GATEWAY\""
  else
    echo "Unknown mode '$MODE'. Use 'tun' or 'tap'."; exit 1
  fi
}

write_server_conf() {
  local NET_DIR="$1" NAME="$2" MODE="$3" PORT="$4" MODE_BLOCK="$5"
  cat > "$NET_DIR/server.conf" <<EOF
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
}

write_verify_script() {
  local NET_DIR="$1"
  cat > "$NET_DIR/verify.sh" <<'SHEOF'
#!/bin/sh
if [ "$depth" = "0" ]; then
  NET_DIR="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$NET_DIR/ccd/$X509_0_CN" ]; exit $?
fi
exit 0
SHEOF
  chmod +x "$NET_DIR/verify.sh"
}

[ $# -lt 4 ] && { echo "Usage: $0 <name> <mode> <port> <subnet>"; exit 1; }

NAME="$1" MODE="$2" PORT="$3" SUBNET="$4"
COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
NET_DIR="$COMMON_DIR/../networks/$NAME"

source "$COMMON_DIR/download-easyrsa.sh"
[ ! -f "$PKI_DIR/ca.crt" ] && { echo "CA not found. Run gen-certs.sh first."; exit 1; }
[ -d "$NET_DIR" ] && { echo "Network '$NAME' already exists at $NET_DIR"; exit 1; }

parse_subnet "$SUBNET"
export EASYRSA_BATCH=1 EASYRSA_NO_PASS=1

mkdir -p "$NET_DIR/ccd" "$NET_DIR/clients"
cp "$PKI_DIR/ca.crt" "$NET_DIR/"

ensure_server_cert "$EASYRSA_DIR" "$PKI_DIR" "$NAME"
cp "$PKI_DIR/issued/${NAME}.crt" "$NET_DIR/server.crt"
cp "$PKI_DIR/private/${NAME}.key" "$NET_DIR/server.key"

ensure_dh_params "$EASYRSA_DIR" "$PKI_DIR"
cp "$PKI_DIR/dh.pem" "$NET_DIR/"

generate_ta_key "$NET_DIR"
make_mode_block "$MODE" "$BASE" "$NETMASK" "$GATEWAY" "$POOL_START" "$POOL_END"
write_server_conf "$NET_DIR" "$NAME" "$MODE" "$PORT" "$MODE_BLOCK"

[ -f "$PKI_DIR/crl.pem" ] && cp "$PKI_DIR/crl.pem" "$NET_DIR/" || touch "$NET_DIR/crl.pem"
write_verify_script "$NET_DIR"
