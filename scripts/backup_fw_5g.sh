#!/bin/zsh
# Read-only backup of an iPod Video (5th/5.5th gen) firmware partition, for porting analysis.
# Reads the device twice and compares hashes. Never writes to the iPod.
# Usage: sudo scripts/backup_fw_5g.sh diskNsM      (partition must be given explicitly)
# Output: firmware/ipod5g_fw_backup.bin (+ .sha256), made read-only.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=67108864
[[ $# -eq 1 ]] || { echo "usage: sudo $0 diskNsM"; exit 1; }
PART=$1; DISK=${PART%s*}
diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }
DEV=/dev/r$PART
OUTDIR="$ROOT/firmware"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ipod5g_fw_backup.bin"
[[ -e "$OUT" ]] && { echo "ABORT: $OUT already exists; refusing to overwrite your backup."; exit 1; }

# Nothing on the iPod may be mounted while we read it.
diskutil unmountDisk "/dev/$DISK"

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
echo "$H1  ipod5g_fw_backup.bin" > "$OUT.sha256"
chown "$OWNER" "$OUT.sha256"
echo "OK: backup verified"
