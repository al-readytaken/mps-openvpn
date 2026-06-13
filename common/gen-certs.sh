#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"

source "$COMMON_DIR/download-easyrsa.sh"

rm -rf "$EASYRSA_DIR/pki"

export EASYRSA_BATCH=1
export EASYRSA_NO_PASS=1
cd "$EASYRSA_DIR"

cp "$COMMON_DIR/vars" .

echo "[*] Initializing PKI ..."
./easyrsa init-pki

echo "[*] Building CA ..."
./easyrsa build-ca nopass

echo "[*] Generating initial CRL ..."
./easyrsa gen-crl

echo "[+] CA created successfully!"
echo "    CA certificate: $EASYRSA_DIR/pki/ca.crt"
echo "    CA key:         $EASYRSA_DIR/pki/private/ca.key"
echo "    CRL:            $EASYRSA_DIR/pki/crl.pem"
