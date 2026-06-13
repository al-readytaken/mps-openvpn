#!/usr/bin/env bash
set -euo pipefail

download_easyrsa() {
  local COMMON_DIR="$1" EASYRSA_DIR="$2" EASYRSA_RELEASE="$3"
  curl -fsSL "https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_RELEASE}/EasyRSA-${EASYRSA_RELEASE}.tgz" -o /tmp/easyrsa.tgz
  tar xzf /tmp/easyrsa.tgz -C "$COMMON_DIR"
  mv "$COMMON_DIR/EasyRSA-${EASYRSA_RELEASE}" "$EASYRSA_DIR"
  rm /tmp/easyrsa.tgz
}

(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

EASYRSA_RELEASE="3.2.2"
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"

if [ -f "$EASYRSA_DIR/easyrsa" ]; then
  if [ "$SOURCED" = "1" ]; then return 0; else exit 0; fi
fi

download_easyrsa "$COMMON_DIR" "$EASYRSA_DIR" "$EASYRSA_RELEASE"
