#!/usr/bin/env bash
set -euo pipefail

load_env() {
  local COMMON_DIR="$1"
  local ENV_FILE="$COMMON_DIR/../.env"
  if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; fi
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
  local NET_DIR="$1" CLIENT="$2" FIXED_IP="$3"
  local CCD_FILE="$NET_DIR/ccd/$CLIENT"
  if [ -f "$CCD_FILE" ]; then return; fi
  if [ -n "$FIXED_IP" ]; then
    local DEV=$(grep '^dev ' "$NET_DIR/server.conf" | awk '{print $2}')
    local MODE="${DEV%%-*}"
    if [ "$MODE" != "tap" ]; then
      echo "Warning: Fixed IP only for TAP; ignoring for $(basename "$NET_DIR")" >&2
      echo "# $CLIENT" > "$CCD_FILE"
    else
      local NETMASK=$(grep '^ifconfig ' "$NET_DIR/server.conf" | awk '{print $3}')
      echo "ifconfig-push $FIXED_IP $NETMASK" > "$CCD_FILE"
    fi
  else
    echo "# $CLIENT" > "$CCD_FILE"
  fi
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
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
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

  if [ -s "$NET_DIR/ta.key" ]; then
    cat >> "$OVPN" <<EOF
<tls-crypt>
$(cat "$NET_DIR/ta.key")
</tls-crypt>
EOF
  fi
}

setup_client_for_network() {
  local NET="$1" FIXED_IP="$2" PROJECT_DIR="$3" PKI_DIR="$4" CLIENT="$5" SERVER_ADDRESS="$6"
  local NET_DIR="$PROJECT_DIR/networks/$NET"
  if [ ! -f "$NET_DIR/server.conf" ]; then
    echo "Network '$NET' not found."; return 1
  fi
  write_ccd_marker "$NET_DIR" "$CLIENT" "$FIXED_IP"
  write_ovpn "$NET_DIR" "$PKI_DIR" "$CLIENT" "$SERVER_ADDRESS"
}

if [ $# -lt 2 ]; then echo "Usage: $0 <client-name> <network[=ip]> [network[=ip] ...]"; exit 1; fi

CLIENT="$1"; shift
NET_NAMES=(); declare -A NET_IPS
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    name="${arg%%=*}"; ip="${arg#*=}"
    NET_IPS["$name"]="$ip"; NET_NAMES+=("$name")
  else
    NET_NAMES+=("$arg")
  fi
done
COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
PROJECT_DIR="$COMMON_DIR/.."

load_env "$COMMON_DIR"
source "$COMMON_DIR/download-easyrsa.sh"
if [ ! -f "$PKI_DIR/ca.crt" ]; then echo "CA not found. Run gen-certs.sh first."; exit 1; fi

export EASYRSA_BATCH=1 EASYRSA_NO_PASS=1
ensure_client_cert "$EASYRSA_DIR" "$PKI_DIR" "$CLIENT"
CLIENT_DIR="$COMMON_DIR/clients/$CLIENT"
copy_client_certs "$PKI_DIR" "$CLIENT_DIR" "$CLIENT"

for NET in "${NET_NAMES[@]}"; do
  setup_client_for_network "$NET" "${NET_IPS[$NET]:-}" "$PROJECT_DIR" "$PKI_DIR" "$CLIENT" "$SERVER_ADDRESS"
done

ARCHIVE_DIR=$(mktemp -d)

for NET in "${NET_NAMES[@]}"; do
  OVPN="$PROJECT_DIR/networks/$NET/clients/$CLIENT.ovpn"
  if [ -f "$OVPN" ]; then cp "$OVPN" "$ARCHIVE_DIR/${NET}.ovpn"; fi
done

mkdir -p "$ARCHIVE_DIR/certs"
cp "$CLIENT_DIR/$CLIENT.crt" "$CLIENT_DIR/$CLIENT.key" "$CLIENT_DIR/ca.crt" "$ARCHIVE_DIR/certs/"

cat > "$ARCHIVE_DIR/install-debian.sh" << SHEOF
#!/usr/bin/env bash
set -euo pipefail

apt update && apt install -y openvpn

# Optional GUI/tray integration (uncomment if needed):
# apt install -y network-manager-openvpn network-manager-openvpn-gnome

SHEOF
for NET in "${NET_NAMES[@]}"; do
  cat >> "$ARCHIVE_DIR/install-debian.sh" << SHEOF
cp "$NET.ovpn" /etc/openvpn/client/$NET.conf
systemctl enable --now openvpn-client@$NET
SHEOF
done
chmod +x "$ARCHIVE_DIR/install-debian.sh"

tar czf "$CLIENT_DIR/$CLIENT.tar.gz" -C "$ARCHIVE_DIR" .
rm -rf "$ARCHIVE_DIR"
