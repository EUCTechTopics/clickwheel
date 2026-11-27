#!/bin/zsh
# iPod Video 5.5G: change the firmware partition from image FROM to image TO, writing only the
# 2048-byte sectors that differ (inside the osos and aupd images; aupd holds the boot logo, --logo).
# The 5.5G's disk uses 2048-byte sectors, so it is only ever written in whole 2048-byte sectors.
# The rest of the partition, including the hibernation image, is left untouched. Reads everything
# from 0 to the end of aupd back afterwards.
# Usage: sudo scripts/write_fw_55g.sh diskNsM [TO.bin] [FROM.bin]
#   defaults: TO = firmware/ipod55g_fw_patched.bin, FROM = firmware/ipod55g_fw_backup.bin
# Both images need a matching .sha256.
set -euo pipefail
ROOT=${0:A:h:h}
EXPECTED=167772160
LIMIT=0xD43000        # end of aupd (0xC3C800 + 0x106800); osos, rsrc and aupd lie below, hibe starts at 0xD44000
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [TO.bin] [FROM.bin]"; exit 1; }
PART=$1; DISK=${PART%s*}
TO=${2:-$ROOT/firmware/ipod55g_fw_patched.bin}
FROM=${3:-$ROOT/firmware/ipod55g_fw_backup.bin}
for f in "$FROM" "$TO"; do
  [[ -f "$f" && -f "$f.sha256" ]] || { echo "ABORT: $f or $f.sha256 missing"; exit 1; }
  [[ $(cut -d' ' -f1 "$f.sha256") == $(shasum -a 256 "$f" | cut -d' ' -f1) ]] || { echo "ABORT: $f does not match its .sha256"; exit 1; }
  [[ $(stat -f %z "$f") == $EXPECTED ]] || { echo "ABORT: $f has the wrong size"; exit 1; }
done

diskutil info "$DISK" | grep -q "Media Name:.*iPod" || { echo "ABORT: $DISK is not an iPod"; exit 1; }
diskutil info "$PART" | grep -q "Partition Type:.*Apple_MDFW" || { echo "ABORT: $PART is not Apple_MDFW"; exit 1; }
diskutil info "$PART" | grep -q "($EXPECTED Bytes)" || { echo "ABORT: $PART is not $EXPECTED bytes"; exit 1; }
diskutil info "$PART" | grep -q "Device Block Size:.*2048 Bytes" || { echo "ABORT: $PART does not use 2048-byte sectors"; exit 1; }

MODEL=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$MODEL" == 55g || "$MODEL" == unknown ]] || { echo "ABORT: this iPod is identified as '$MODEL', not an iPod Video 5.5G."; exit 1; }

# Nothing on the iPod may be mounted while writing.
diskutil unmountDisk "/dev/$DISK"

echo "Changing /dev/r$PART from $(basename "$FROM") to $(basename "$TO")"
/usr/bin/python3 -I "$ROOT/scripts/write_sectors.py" "$FROM" "$TO" "/dev/r$PART" "$LIMIT" 2048
sync
echo "OK: firmware partition now matches $(basename "$TO") (osos + aupd area; rest untouched)"
echo "Next: diskutil eject $DISK, unplug, then hold Menu + Select until the Apple logo appears."
