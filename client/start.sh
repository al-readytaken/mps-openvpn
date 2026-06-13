#!/bin/bash
mkdir -p /var/log

CLIENT_NAME="${CLIENT_NAME:-}"
NETWORKS="${NETWORKS:-}"

if [ -z "$CLIENT_NAME" ] || [ -z "$NETWORKS" ]; then
  echo "[!] CLIENT_NAME and NETWORKS env vars must be set."
  echo "    Example: CLIENT_NAME=alice NETWORKS=office-tun,guest-tun"
  exit 1
fi

IFS=, read -ra nets <<< "$NETWORKS"

found=0
for net in "${nets[@]}"; do
  net="$(echo "$net" | xargs)"
  ovpn="/etc/openvpn/networks/${net}/clients/${CLIENT_NAME}.ovpn"
  if [ -f "$ovpn" ]; then
    echo "[*] Connecting '$CLIENT_NAME' to network '$net' ..."
    openvpn --config "$ovpn" \
      --log "/var/log/${net}.log" \
      --writepid "/var/run/openvpn-${net}.pid" &
    found=$((found + 1))
  else
    echo "[!] No config found: $ovpn"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "[!] No valid client configs found."
  exit 1
fi

echo "[+] Connected to $found network(s). Waiting ..."
trap 'kill $(jobs -p); exit 0' INT TERM
wait
