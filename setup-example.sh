#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$ROOT_DIR/common/gen-certs.sh"
"$ROOT_DIR/common/gen-network.sh" office-tun tun 1194 10.8.0.0/24
"$ROOT_DIR/common/gen-network.sh" guest-tun tun 1196 10.10.0.0/24
"$ROOT_DIR/common/gen-network.sh" iot-tap   tap 1197 10.11.0.0/24

echo "Server setup complete. Run docker compose up -d --build to start."
