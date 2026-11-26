#!/bin/zsh
# Read-only backup of the iPod firmware partition. Reads the device twice and compares hashes.
# Usage: sudo scripts/backup_fw.sh [diskNsM]       (auto-detects the partition if omitted)
# Output: firmware/ipod_fw_backup.bin (+ .sha256), made read-only.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=33554432
PART=$("$ROOT/scripts/find_ipod.sh" "$@")
DEV=/dev/r$PART
OUTDIR="$ROOT/firmware"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ipod_fw_backup.bin"
[[ -e "$OUT" ]] && { echo "ABORT: $OUT already exists; refusing to overwrite your backup."; exit 1; }

MODEL=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$MODEL" == 4g || "$MODEL" == unknown ]] || { echo "ABORT: this iPod is identified as '$MODEL', not an iPod 4G (BoardHwName iPod Q21); for an iPod photo use the *_photo.sh scripts."; exit 1; }

# Nothing on the iPod may be mounted while we read it.
diskutil unmountDisk "/dev/${PART%s*}"

echo "Reading $DEV -> $OUT"
dd if="$DEV" of="$OUT" bs=1m
OWNER=${SUDO_USER:-$USER}
chown "$OWNER" "$OUTDIR" "$OUT"
chmod 444 "$OUT"

SIZE=$(stat -f %z "$OUT")
echo "backup size: $SIZE (expected $EXPECTED)"
[[ "$SIZE" == "$EXPECTED" ]] || { echo "SIZE MISMATCH"; exit 1; }

H1=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
H2=$(dd if="$DEV" bs=1m 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
echo "sha256 backup file : $H1"
echo "sha256 second read : $H2"
[[ "$H1" == "$H2" ]] || { echo "CHECKSUM MISMATCH between the two reads"; exit 1; }
echo "$H1  ipod_fw_backup.bin" > "$OUT.sha256"
chown "$OWNER" "$OUT.sha256"
echo "OK: backup verified"
