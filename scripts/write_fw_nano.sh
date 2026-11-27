#!/bin/zsh
# iPod nano (1st gen): change the firmware partition from image FROM to image TO, writing only the
# 512-byte sectors that differ (inside the osos and aupd images; aupd holds the boot logo, --logo).
# The rest of the partition, including the hibernation image, is left untouched. Reads everything
# from 0 to the end of aupd back afterwards.
# Usage: sudo scripts/write_fw_nano.sh diskNsM [TO.bin] [FROM.bin]
#   defaults: TO = firmware/ipodnano_fw_patched.bin, FROM = firmware/ipodnano_fw_backup.bin
# Both images need a matching .sha256.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=67108864
LIMIT=0x15D8C00        # end of aupd (0x1553A00 + 0x851DC, rounded to a sector); osos, rsrc and aupd lie below, hibe starts at 0x15D8E00
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [TO.bin] [FROM.bin]"; exit 1; }
PART=$1; DISK=${PART%s*}
TO=${2:-$ROOT/firmware/ipodnano_fw_patched.bin}
FROM=${3:-$ROOT/firmware/ipodnano_fw_backup.bin}
for f in "$FROM" "$TO"; do
  [[ -f "$f" && -f "$f.sha256" ]] || { echo "ABORT: $f or $f.sha256 missing"; exit 1; }
  [[ $(cut -d' ' -f1 "$f.sha256") == $(shasum -a 256 "$f" | cut -d' ' -f1) ]] || { echo "ABORT: $f does not match its .sha256"; exit 1; }
  [[ $(stat -f %z "$f") == $EXPECTED ]] || { echo "ABORT: $f has the wrong size"; exit 1; }
done

diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }

MODEL=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$MODEL" == nano ]] || { echo "ABORT: this iPod is identified as '$MODEL', not an iPod nano (USB product 4618)."; exit 1; }

# Nothing on the iPod may be mounted while writing.
diskutil unmountDisk "/dev/$DISK"

echo "Changing /dev/r$PART from $(basename "$FROM") to $(basename "$TO")"
/usr/bin/python3 -I "$ROOT/scripts/write_sectors.py" "$FROM" "$TO" "/dev/r$PART" "$LIMIT"
sync
echo "OK: firmware partition now matches $(basename "$TO") (osos + aupd area; rest untouched)"
echo "Next: diskutil eject $DISK, unplug, then hold Menu + Select until the Apple logo appears."
