#!/bin/zsh
# iPod Video 5.5G: put the original bytes from firmware/ipod55g_fw_backup.bin back, undoing
# firmware/ipod55g_fw_patched.bin (only the sectors that differ are written).
# Usage: sudo scripts/rollback_fw_55g.sh diskNsM [PATCHED.bin]
set -euo pipefail
ROOT=${0:A:h:h}
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [PATCHED.bin]"; exit 1; }
exec "$ROOT/scripts/write_fw_55g.sh" "$1" "$ROOT/firmware/ipod55g_fw_backup.bin" "${2:-$ROOT/firmware/ipod55g_fw_patched.bin}"
