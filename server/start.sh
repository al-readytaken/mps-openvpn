#!/bin/sh

mkdir -p /var/log
NETWORK_DIR="/etc/openvpn/networks"

found=0
for conf in "$NETWORK_DIR"/*/server.conf; do
  [ -f "$conf" ] || continue
  name="$(basename "$(dirname "$conf")")"
  openvpn --config "$conf" --log "/var/log/${name}.log" --writepid "/var/run/openvpn-${name}.pid" &
  found=$((found + 1))
done

[ "$found" -eq 0 ] && { echo "No network configs found in $NETWORK_DIR"; exit 0; }

trap 'kill $(jobs -p); exit 0' INT TERM
wait
