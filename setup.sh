#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Step 1: Create Certificate Authority ==="
bash "$ROOT_DIR/common/gen-certs.sh"

echo ""
echo "=== Step 2: Create Networks ==="
# (adjust ports/subnets as needed; add more gen-network.sh lines below)
bash "$ROOT_DIR/common/gen-network.sh" office-tun tun 1194 10.8.0.0/24
bash "$ROOT_DIR/common/gen-network.sh" guest-tun tun 1196 10.10.0.0/24
bash "$ROOT_DIR/common/gen-network.sh" iot-tap   tap 1197 10.11.0.0/24

echo ""
echo "=== Step 3: Create Clients ==="
bash "$ROOT_DIR/common/gen-client.sh" alice office-tun guest-tun
bash "$ROOT_DIR/common/gen-client.sh" bob   office-tun

echo ""
echo "=== Step 4: Build Docker images ==="
docker compose -f "$ROOT_DIR/docker-compose.yml" build

echo ""
echo "=== Step 5: Start containers ==="
docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Check logs:"
echo "  docker compose logs -f"
echo ""
echo "Test TUN (office-tun via 10.8.0.1):"
echo "  docker exec openvpn-client-alice ping -c 3 10.8.0.1"
echo ""
echo "Test TAP (iot-tap via 10.11.0.1):"
echo "  docker exec openvpn-client-alice ping -c 3 10.11.0.1"
echo ""
echo "List available networks and clients:"
echo "  ls -la networks/*/clients/"
echo ""
echo "Add a new client:"
echo "  ./common/gen-client.sh charlie office-tun guest-tun iot-tap"
echo "Then add a 'charlie' service to docker-compose.yml and re-up."
