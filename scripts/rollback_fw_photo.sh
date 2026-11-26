#!/bin/zsh
# iPod photo / iPod color: put the original bytes from firmware/ipodphoto_fw_backup.bin back, undoing
# firmware/ipodphoto_fw_patched.bin (only the sectors that differ are written).
# Usage: sudo scripts/rollback_fw_photo.sh diskNsM [PATCHED.bin]
set -euo pipefail
ROOT=${0:A:h:h}
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [PATCHED.bin]"; exit 1; }
exec "$ROOT/scripts/write_fw_photo.sh" "$1" "$ROOT/firmware/ipodphoto_fw_backup.bin" "${2:-$ROOT/firmware/ipodphoto_fw_patched.bin}"
