#!/bin/zsh
# Read-only backup of an iPod nano (1st gen) firmware partition (64 MiB, the same size as the iPod Video 5G),
# for porting analysis. Reads the device twice and compares hashes. Never writes to the iPod.
# Usage: sudo scripts/backup_fw_nano.sh diskNsM      (partition must be given explicitly)
# Output: firmware/ipodnano_fw_backup.bin (+ .sha256), made read-only.
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
OUT="$OUTDIR/ipodnano_fw_backup.bin"
[[ -e "$OUT" ]] && { echo "ABORT: $OUT already exists; refusing to overwrite your backup."; exit 1; }

# A nano's partition is the same size as an iPod Video 5G's; the nano 1G has USB product ID 0x120A
# (4618). Refuse unless exactly one iPod is connected and it is a nano.
# (ipod_model.sh says 'nano' for it too, via usb_product.py)
IDS=($(ioreg -p IOUSB -l -w0 | awk -F'= ' '/"USB Product Name" = "iPod"/ {ipod=1} ipod && /"idProduct"/ {print $2; ipod=0}'))
[[ ${#IDS} -eq 1 && "${IDS[1]}" == 4618 ]] || { echo "ABORT: expected exactly one connected iPod, an iPod nano (USB product 4618); found: ${IDS[*]:-none}"; exit 1; }

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
echo "$H1  ipodnano_fw_backup.bin" > "$OUT.sha256"
chown "$OWNER" "$OUT.sha256"
diskutil mountDisk "/dev/$DISK" >/dev/null 2>&1 || true
echo "OK: backup verified"
