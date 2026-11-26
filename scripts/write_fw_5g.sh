#!/bin/zsh
# iPod Video 5G: change the firmware partition from image FROM to image TO, writing only the
# 512-byte sectors that differ (all inside the osos area). The rest of the partition, including
# the hibernation image, is left untouched. Reads everything back afterwards.
# Usage: sudo scripts/write_fw_5g.sh diskNsM [TO.bin] [FROM.bin]
#   defaults: TO = firmware/ipod5g_fw_patched.bin, FROM = firmware/ipod5g_fw_backup.bin
# Both images need a matching .sha256.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=67108864
OSOS_END=0x73A000     # partition offset where the osos image ends (0x4600 + 0x735A00)
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [TO.bin] [FROM.bin]"; exit 1; }
PART=$1; DISK=${PART%s*}
TO=${2:-$ROOT/firmware/ipod5g_fw_patched.bin}
FROM=${3:-$ROOT/firmware/ipod5g_fw_backup.bin}
for f in "$FROM" "$TO"; do
  [[ -f "$f" && -f "$f.sha256" ]] || { echo "ABORT: $f or $f.sha256 missing"; exit 1; }
  [[ $(cut -d' ' -f1 "$f.sha256") == $(shasum -a 256 "$f" | cut -d' ' -f1) ]] || { echo "ABORT: $f does not match its .sha256"; exit 1; }
  [[ $(stat -f %z "$f") == $EXPECTED ]] || { echo "ABORT: $f has the wrong size"; exit 1; }
done

diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }

# Nothing on the iPod may be mounted while writing.
diskutil unmountDisk "/dev/$DISK"

echo "Changing /dev/r$PART from $(basename "$FROM") to $(basename "$TO")"
/usr/bin/python3 -I "$ROOT/scripts/write_sectors.py" "$FROM" "$TO" "/dev/r$PART" "$OSOS_END"
sync
echo "OK: firmware partition now matches $(basename "$TO") (osos area; rest untouched)"
echo "Next: diskutil eject $DISK, unplug, then hold Menu + Select until the Apple logo appears."
