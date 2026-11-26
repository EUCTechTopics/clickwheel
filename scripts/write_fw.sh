#!/bin/zsh
# Write a verified firmware image to the iPod firmware partition and read it back.
# Usage: sudo scripts/write_fw.sh <image.bin> [diskNsM]   (auto-detects the partition if omitted)
# The image must have a matching <image.bin>.sha256 (created by backup_fw.sh / patch.py).
set -euo pipefail
ROOT=${0:A:h:h}
IMG="${1:?usage: sudo $0 <image.bin> [diskNsM]}"
shift
EXPECTED=33554432
[[ "$IMG" == /* || -f "$IMG" ]] || IMG="$ROOT/firmware/$IMG"

[[ -f "$IMG" && -f "$IMG.sha256" ]] || { echo "ABORT: $IMG or $IMG.sha256 missing"; exit 1; }
WANT=$(cut -d' ' -f1 "$IMG.sha256")
HAVE=$(shasum -a 256 "$IMG" | cut -d' ' -f1)
[[ "$WANT" == "$HAVE" ]] || { echo "ABORT: $IMG does not match its .sha256"; exit 1; }
[[ $(stat -f %z "$IMG") == $EXPECTED ]] || { echo "ABORT: $IMG has the wrong size"; exit 1; }

PART=$("$ROOT/scripts/find_ipod.sh" "$@")
DISK=${PART%s*}

MODEL=$("$ROOT/scripts/ipod_model.sh" "$PART")
[[ "$MODEL" == 4g || "$MODEL" == unknown ]] || { echo "ABORT: this iPod is identified as '$MODEL', not an iPod 4G (BoardHwName iPod Q21); for an iPod photo use the *_photo.sh scripts."; exit 1; }

# Nothing on the iPod may be mounted while writing.
diskutil unmountDisk "/dev/$DISK"

# The device must already hold firmware of the same model as the image (same osos image length in
# its directory). This works without the data volume, so it also protects a rollback.
/usr/bin/python3 -I "$ROOT/scripts/same_model.py" "/dev/r$PART" "$IMG" || exit 1

echo "Writing $IMG -> /dev/r$PART"
dd if="$IMG" of="/dev/r$PART" bs=1m
sync

BACK=$(dd if="/dev/r$PART" bs=1m 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
echo "image sha256    : $WANT"
echo "readback sha256 : $BACK"
[[ "$BACK" == "$WANT" ]] || { echo "READBACK MISMATCH - do not unplug; run scripts/rollback_fw.sh"; exit 1; }
echo "OK: firmware partition now matches $(basename "$IMG")"
echo "Next: diskutil eject $DISK, unplug, then hold Menu + Select until the Apple logo appears."
