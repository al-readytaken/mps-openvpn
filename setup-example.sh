#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

TUN_NET="${TUN_NET:-default-tun}"
TAP_NET="${TAP_NET:-default-tap}"
TUN_SUBNET="${TUN_SUBNET:-10.23.44.0/24}"
TAP_SUBNET="${TAP_SUBNET:-10.23.43.0/24}"
TUN_PORT="${TUN_PORT:-1194}"
TAP_PORT="${TAP_PORT:-1195}"
TAP_CLIENTS="${TAP_CLIENTS:-3}"
CLIENT_PREFIX="${CLIENT_PREFIX:-t}"

"$ROOT_DIR/common/gen-certs.sh"
"$ROOT_DIR/common/gen-network.sh" "$TUN_NET" tun "$TUN_PORT" "$TUN_SUBNET"
"$ROOT_DIR/common/gen-network.sh" "$TAP_NET" tap "$TAP_PORT" "$TAP_SUBNET"

TAP_PREFIX="${TAP_SUBNET%.*}"
for i in $(seq 1 "$TAP_CLIENTS"); do
  "$ROOT_DIR/common/gen-client.sh" "${CLIENT_PREFIX}${i}" "${TAP_NET}=${TAP_PREFIX}.$((i * 10))"
done

TUN_IDX=$((TAP_CLIENTS + 1))
"$ROOT_DIR/common/gen-client.sh" "${CLIENT_PREFIX}${TUN_IDX}" "$TUN_NET"

echo "Server setup complete. Run docker compose up -d --build to start."
echo "Client archives: common/clients/{${CLIENT_PREFIX}*}/*.tar.gz"
