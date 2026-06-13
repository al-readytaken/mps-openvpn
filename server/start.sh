#!/bin/sh
mkdir -p /var/log

NETWORK_DIR="/etc/openvpn/networks"
found=0

for conf in "$NETWORK_DIR"/*/server.conf; do
  [ -f "$conf" ] || continue
  name="$(basename "$(dirname "$conf")")"
  echo "[*] Starting OpenVPN instance for network '$name' ..."
  openvpn --config "$conf" \
    --log "/var/log/${name}.log" \
    --writepid "/var/run/openvpn-${name}.pid" &
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "[!] No network configs found in $NETWORK_DIR"
  echo "    Create networks with: common/gen-network.sh"
  exit 0
fi

echo "[+] Started $found OpenVPN instance(s). Waiting ..."
trap 'kill $(jobs -p); exit 0' INT TERM
wait
