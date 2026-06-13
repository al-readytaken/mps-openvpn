#!/usr/bin/env bash
set -euo pipefail

write_vars() {
  local EASYRSA_DIR="$1"
  cat > "$EASYRSA_DIR/vars" <<EOF
if [ -z "\$EASYRSA" ]; then EASYRSA=.; fi
set_var EASYRSA_REQ_COUNTRY    "${EASYRSA_REQ_COUNTRY:-US}"
set_var EASYRSA_REQ_PROVINCE   "${EASYRSA_REQ_PROVINCE:-California}"
set_var EASYRSA_REQ_CITY       "${EASYRSA_REQ_CITY:-San Francisco}"
set_var EASYRSA_REQ_ORG        "${EASYRSA_REQ_ORG:-MPS OpenVPN}"
set_var EASYRSA_REQ_EMAIL      "${EASYRSA_REQ_EMAIL:-admin@example.com}"
set_var EASYRSA_REQ_OU         "${EASYRSA_REQ_OU:-TestLab}"
set_var EASYRSA_KEY_SIZE        ${EASYRSA_KEY_SIZE:-2048}
set_var EASYRSA_ALGO            ${EASYRSA_ALGO:-rsa}
set_var EASYRSA_CA_EXPIRE       ${EASYRSA_CA_EXPIRE:-3650}
set_var EASYRSA_CERT_EXPIRE     ${EASYRSA_CERT_EXPIRE:-3650}
set_var EASYRSA_BATCH           "yes"
set_var EASYRSA_NO_PASS         1
EOF
}

bootstrap_ca() {
  local EASYRSA_DIR="$1"
  rm -rf "$EASYRSA_DIR/pki"
  export EASYRSA_BATCH=1 EASYRSA_NO_PASS=1
  cd "$EASYRSA_DIR"
  write_vars "$EASYRSA_DIR"
  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa gen-crl
}

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYRSA_DIR="$COMMON_DIR/easy-rsa"

source "$COMMON_DIR/download-easyrsa.sh"
[ -f "$COMMON_DIR/../.env" ] && source "$COMMON_DIR/../.env"
bootstrap_ca "$EASYRSA_DIR"
