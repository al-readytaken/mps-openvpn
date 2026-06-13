#!/usr/bin/env bash
set -euo pipefail

load_env() {
  local COMMON_DIR="$1"
  local ENV_FILE="$COMMON_DIR/../.env"
  [ -f "$ENV_FILE" ] && source "$ENV_FILE"
  SERVER_ADDRESS="${SERVER_ADDRESS:-server}"
}

ensure_client_cert() {
  local EASYRSA_DIR="$1" PKI_DIR="$2" CLIENT="$3"
  cd "$EASYRSA_DIR"
  if [ ! -f "$PKI_DIR/issued/${CLIENT}.crt" ]; then
    ./easyrsa gen-req "$CLIENT" nopass
    ./easyrsa sign-req client "$CLIENT"
  fi
}

copy_client_certs() {
  local PKI_DIR="$1" CLIENT_DIR="$2" CLIENT="$3"
  mkdir -p "$CLIENT_DIR"
  cp "$PKI_DIR/issued/${CLIENT}.crt" "$PKI_DIR/private/${CLIENT}.key" "$PKI_DIR/ca.crt" "$CLIENT_DIR/"
}

write_ccd_marker() {
  local NET_DIR="$1" CLIENT="$2"
  local CCD_FILE="$NET_DIR/ccd/$CLIENT"
  [ ! -f "$CCD_FILE" ] && echo "# $CLIENT" > "$CCD_FILE"
}

write_ovpn() {
  local NET_DIR="$1" PKI_DIR="$2" CLIENT="$3" SERVER_ADDRESS="$4"
  local PORT=$(grep '^port ' "$NET_DIR/server.conf" | awk '{print $2}')
  local MODE=$(grep '^dev ' "$NET_DIR/server.conf" | awk '{print $2}')
  local OVPN="$NET_DIR/clients/$CLIENT.ovpn"

  cat > "$OVPN" <<EOF
client
dev $MODE
proto udp
remote $SERVER_ADDRESS $PORT
resolv-retry infinite
nobind
remote-cert-tls server
persist-key
persist-tun
verb 3
<ca>
$(cat "$NET_DIR/ca.crt")
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$PKI_DIR/issued/${CLIENT}.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/${CLIENT}.key")
</key>
EOF

  [ -s "$NET_DIR/ta.key" ] && cat >> "$OVPN" <<EOF
<tls-crypt>
$(cat "$NET_DIR/ta.key")
</tls-crypt>
EOF
}

setup_client_for_network() {
  local NET="$1" PROJECT_DIR="$2" PKI_DIR="$3" CLIENT="$4" SERVER_ADDRESS="$5"
  local NET_DIR="$PROJECT_DIR/networks/$NET"
  [ ! -f "$NET_DIR/server.conf" ] && { echo "Network '$NET' not found."; return 1; }
  write_ccd_marker "$NET_DIR" "$CLIENT"
  write_ovpn "$NET_DIR" "$PKI_DIR" "$CLIENT" "$SERVER_ADDRESS"
}

[ $# -lt 2 ] && { echo "Usage: $0 <client-name> <network> [network ...]"; exit 1; }

CLIENT="$1"; shift
NETWORKS=("$@")
COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
PROJECT_DIR="$COMMON_DIR/.."

load_env "$COMMON_DIR"
source "$COMMON_DIR/download-easyrsa.sh"
[ ! -f "$PKI_DIR/ca.crt" ] && { echo "CA not found. Run gen-certs.sh first."; exit 1; }

export EASYRSA_BATCH=1 EASYRSA_NO_PASS=1
ensure_client_cert "$EASYRSA_DIR" "$PKI_DIR" "$CLIENT"
copy_client_certs "$PKI_DIR" "$COMMON_DIR/clients/$CLIENT" "$CLIENT"

for NET in "${NETWORKS[@]}"; do
  setup_client_for_network "$NET" "$PROJECT_DIR" "$PKI_DIR" "$CLIENT" "$SERVER_ADDRESS"
done

ARCHIVE_DIR=$(mktemp -d)

for NET in "${NETWORKS[@]}"; do
  OVPN="$PROJECT_DIR/networks/$NET/clients/$CLIENT.ovpn"
  [ -f "$OVPN" ] && cp "$OVPN" "$ARCHIVE_DIR/${NET}.ovpn"
done

mkdir -p "$ARCHIVE_DIR/certs"
cp "$CLIENT_DIR/$CLIENT.crt" "$CLIENT_DIR/$CLIENT.key" "$CLIENT_DIR/ca.crt" "$ARCHIVE_DIR/certs/"

cat > "$ARCHIVE_DIR/install-debian.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
apt update && apt install -y openvpn network-manager-openvpn network-manager-openvpn-gnome
SHEOF
chmod +x "$ARCHIVE_DIR/install-debian.sh"

tar czf "$CLIENT_DIR/$CLIENT.tar.gz" -C "$ARCHIVE_DIR" .
rm -rf "$ARCHIVE_DIR"
