#!/bin/zsh
# Read-only: print which supported model a firmware partition belongs to: 4g, 5g, 55g, nano, photo or unknown.
# Uses SysInfo (BoardHwName) when the iPod's data volume is mounted, else the partition size; a 64 MiB
# partition is a nano when the iPod's USB product ID is 4618 (0x120A), else an iPod Video 5G.
# Usage: scripts/ipod_model.sh diskNsM
set -uo pipefail
PART=${1:?usage: $0 diskNsM}; DISK=${PART%s*}
SIZE=$(diskutil info "$PART" 2>/dev/null | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p' | head -1)
BOARD=""
MNT=$(diskutil info "${DISK}s3" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
if [[ -n "${MNT:-}" && -f "$MNT/iPod_Control/Device/SysInfo" ]]; then
  BOARD=$(awk -F': *' '/^BoardHwName/ {print $2}' "$MNT/iPod_Control/Device/SysInfo" 2>/dev/null)
fi
case "$BOARD" in
  "iPod Q21") echo 4g ;;
  "iPod P98") echo photo ;;
  "") case "$SIZE" in
        67108864) [[ "$(/usr/bin/python3 -I "${0:A:h}/usb_product.py" "$PART")" == 4618 ]] && echo nano || echo 5g ;;
        167772160) echo 55g ;;
        *) echo unknown ;;
      esac ;;
  *) echo unknown ;;
esac
