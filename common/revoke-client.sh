#!/usr/bin/env bash
set -euo pipefail

revoke_and_update_crl() {
  local EASYRSA_DIR="$1" CLIENT="$2"
  cd "$EASYRSA_DIR"
  ./easyrsa revoke "$CLIENT"
  ./easyrsa gen-crl
}

push_crl() {
  local PKI_DIR="$1" PROJECT_DIR="$2"
  for NET_DIR in "$PROJECT_DIR/networks/"*/; do
    [ -f "$NET_DIR/server.conf" ] && cp "$PKI_DIR/crl.pem" "$NET_DIR/crl.pem"
  done
}

[ $# -lt 1 ] && { echo "Usage: $0 <client-name>"; exit 1; }

CLIENT="$1"
COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"
PROJECT_DIR="$COMMON_DIR/.."

source "$COMMON_DIR/download-easyrsa.sh"
[ ! -f "$PKI_DIR/issued/${CLIENT}.crt" ] && { echo "No certificate found for '$CLIENT'."; exit 1; }

export EASYRSA_BATCH=1
revoke_and_update_crl "$EASYRSA_DIR" "$CLIENT"
push_crl "$PKI_DIR" "$PROJECT_DIR"
