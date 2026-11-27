#!/bin/zsh
# Read-only backup of an iPod Video 5.5th gen firmware partition (160 MiB, 2048-byte sectors),
# for porting analysis. Reads the device twice and compares hashes. Never writes to the iPod.
# Usage: sudo scripts/backup_fw_55g.sh diskNsM      (partition must be given explicitly)
# Output: firmware/ipod55g_fw_backup.bin (+ .sha256), made read-only.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=167772160
[[ $# -eq 1 ]] || { echo "usage: sudo $0 diskNsM"; exit 1; }
PART=$1; DISK=${PART%s*}
diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }
DEV=/dev/r$PART
OUTDIR="$ROOT/firmware"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ipod55g_fw_backup.bin"
[[ -e "$OUT" ]] && { echo "ABORT: $OUT already exists; refusing to overwrite your backup."; exit 1; }

MODEL=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$MODEL" == 55g || "$MODEL" == unknown ]] || { echo "ABORT: this iPod is identified as '$MODEL', not an iPod Video 5.5G."; exit 1; }

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
echo "$H1  ipod55g_fw_backup.bin" > "$OUT.sha256"
chown "$OWNER" "$OUT.sha256"
diskutil mountDisk "/dev/$DISK" >/dev/null 2>&1 || true
echo "OK: backup verified"
