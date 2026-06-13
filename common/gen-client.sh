#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <client-name> <network> [network ...]"
  echo ""
  echo "Examples:"
  echo "  $0 alice office-tun guest-tun"
  echo "  $0 bob office-tun"
  exit 1
fi

CLIENT="$1"
shift
NETWORKS=("$@")

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
PROJECT_DIR="$COMMON_DIR/.."

source "$COMMON_DIR/download-easyrsa.sh"

if [ ! -f "$PKI_DIR/ca.crt" ]; then
  echo "[!] CA not found. Run gen-certs.sh first."
  exit 1
fi

export EASYRSA_BATCH=1
export EASYRSA_NO_PASS=1
cd "$EASYRSA_DIR"

if [ ! -f "$PKI_DIR/issued/${CLIENT}.crt" ]; then
  echo "[*] Generating client certificate for '$CLIENT' ..."
  ./easyrsa gen-req "$CLIENT" nopass
  ./easyrsa sign-req client "$CLIENT"
else
  echo "[*] Client '$CLIENT' already has a certificate, reusing it."
fi

CLIENT_DIR="$COMMON_DIR/clients/$CLIENT"
mkdir -p "$CLIENT_DIR"
cp "$PKI_DIR/issued/${CLIENT}.crt" "$CLIENT_DIR/"
cp "$PKI_DIR/private/${CLIENT}.key" "$CLIENT_DIR/"
cp "$PKI_DIR/ca.crt" "$CLIENT_DIR/"

echo "    Client certs: $CLIENT_DIR/"

for NET in "${NETWORKS[@]}"; do
  NET_DIR="$PROJECT_DIR/networks/$NET"

  if [ ! -f "$NET_DIR/server.conf" ]; then
    echo "[!] Network '$NET' not found. Skipping."
    continue
  fi

  PORT=$(grep '^port ' "$NET_DIR/server.conf" | awk '{print $2}')
  MODE=$(grep '^dev ' "$NET_DIR/server.conf" | awk '{print $2}')

  echo "[*] Generating .ovpn for '$CLIENT' on network '$NET' ..."

  # Create CCD marker to authorize this client on this network
  CCD_FILE="$NET_DIR/ccd/$CLIENT"
  if [ ! -f "$CCD_FILE" ]; then
    echo "# $CLIENT — authorized on $NET" > "$CCD_FILE"
    echo "    CCD:    $CCD_FILE"
  fi

  # Build inline .ovpn
  OVPN="$NET_DIR/clients/$CLIENT.ovpn"

  cat > "$OVPN" <<EOF
# OpenVPN client config for: $CLIENT on network $NET
client
dev $MODE
proto udp
remote server $PORT
resolv-retry infinite
nobind
remote-cert-tls server
EOF

  cat >> "$OVPN" <<EOF
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

  echo "    Created: $OVPN"
done

echo "[+] Client '$CLIENT' configured for ${#NETWORKS[@]} network(s)."
