#!/bin/zsh
# Read-only: report which patches are on the iPod right now. Reads the firmware partition into a
# temporary file, runs `patch.py --check` on it and deletes the file. Never writes to the iPod and
# doesn't unmount it (the firmware partition is never mounted).
# Usage: sudo scripts/device_state.sh MODEL diskNsM [--json]      MODEL: 4g, 5g, 55g, nano or photo
set -euo pipefail
ROOT=${0:A:h:h}
[[ $# -ge 2 ]] || { echo "usage: sudo $0 4g|5g|55g|nano|photo diskNsM [--json]"; exit 1; }
MODEL=$1; PART=$2; DISK=${PART%s*}; shift 2
case "$MODEL" in
  4g|photo) EXPECTED=33554432 ;;
  5g|nano) EXPECTED=67108864 ;;
  55g) EXPECTED=167772160 ;;
  *) echo "ABORT: unknown model $MODEL"; exit 1 ;;
esac
diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }
DETECTED=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$DETECTED" == "$MODEL" || "$DETECTED" == unknown ]] || { echo "ABORT: this iPod is identified as '$DETECTED', not '$MODEL'"; exit 1; }

TMP=$(mktemp -t clickwheel-state)
trap 'rm -f "$TMP"' EXIT
echo "Reading /dev/r$PART (read-only)…"
dd if="/dev/r$PART" of="$TMP" bs=1m 2>/dev/null
/usr/bin/python3 -I "$ROOT/scripts/patch.py" --model "$MODEL" --check -i "$TMP" "$@" || true
