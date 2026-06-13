#!/bin/bash
set -euo pipefail

start_connections() {
  local CLIENT_NAME="$1" NETWORKS="$2"
  IFS=, read -ra nets <<< "$NETWORKS"
  local found=0

  for net in "${nets[@]}"; do
    net="$(echo "$net" | xargs)"
    local ovpn="/etc/openvpn/networks/${net}/clients/${CLIENT_NAME}.ovpn"
    if [ -f "$ovpn" ]; then
      openvpn --config "$ovpn" --log "/var/log/${net}.log" --writepid "/var/run/openvpn-${net}.pid" &
      found=$((found + 1))
    fi
  done

  echo "$found"
}

mkdir -p /var/log
CLIENT_NAME="${CLIENT_NAME:-}" NETWORKS="${NETWORKS:-}"

[ -z "$CLIENT_NAME" ] || [ -z "$NETWORKS" ] && { echo "CLIENT_NAME and NETWORKS env vars must be set."; exit 1; }

found=$(start_connections "$CLIENT_NAME" "$NETWORKS")
[ "$found" -eq 0 ] && { echo "No valid client configs found."; exit 1; }

trap 'kill $(jobs -p); exit 0' INT TERM
wait
