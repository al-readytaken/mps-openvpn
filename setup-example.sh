#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$ROOT_DIR/common/gen-certs.sh"
"$ROOT_DIR/common/gen-network.sh" guest-tun tun 1194 10.10.0.0/24
"$ROOT_DIR/common/gen-network.sh" default-tap tap 1195 10.11.0.0/24

# Generate clients (TAP gets fixed IP via network=ip syntax)
"$ROOT_DIR/common/gen-client.sh" t1 default-tap=10.11.0.10
"$ROOT_DIR/common/gen-client.sh" t2 default-tap=10.11.0.20
"$ROOT_DIR/common/gen-client.sh" t3 default-tap=10.11.0.30
"$ROOT_DIR/common/gen-client.sh" t4 guest-tun

echo "Server setup complete. Run docker compose up -d --build to start."
echo "Client archives: common/clients/{t1,t2,t3,t4}/*.tar.gz"
