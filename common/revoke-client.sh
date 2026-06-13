#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <client-name>"
  echo ""
  echo "Example:"
  echo "  $0 alice"
  exit 1
fi

CLIENT="$1"

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
PROJECT_DIR="$COMMON_DIR/.."

source "$COMMON_DIR/download-easyrsa.sh"

if [ ! -f "$PKI_DIR/issued/${CLIENT}.crt" ]; then
  echo "[!] No certificate found for '$CLIENT'. Nothing to revoke."
  exit 1
fi

export EASYRSA_BATCH=1
cd "$EASYRSA_DIR"

echo "[*] Revoking certificate for '$CLIENT' ..."
./easyrsa revoke "$CLIENT"

echo "[*] Generating CRL ..."
./easyrsa gen-crl

cp "$PKI_DIR/crl.pem" /tmp/crl.pem

echo "[*] Updating CRL in all networks ..."
for NET_DIR in "$PROJECT_DIR/networks/"*/; do
  if [ -f "$NET_DIR/server.conf" ]; then
    cp /tmp/crl.pem "$NET_DIR/crl.pem"
    echo "    Updated: ${NET_DIR}crl.pem"
  fi
done

rm /tmp/crl.pem

echo "[+] Certificate for '$CLIENT' revoked and CRL updated."
