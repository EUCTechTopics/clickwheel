#!/bin/zsh
# iPod nano (1st gen): put the original bytes from firmware/ipodnano_fw_backup.bin back, undoing
# firmware/ipodnano_fw_patched.bin (only the sectors that differ are written).
# Usage: sudo scripts/rollback_fw_nano.sh diskNsM [PATCHED.bin]
set -euo pipefail
ROOT=${0:A:h:h}
[[ $# -ge 1 ]] || { echo "usage: sudo $0 diskNsM [PATCHED.bin]"; exit 1; }
exec "$ROOT/scripts/write_fw_nano.sh" "$1" "$ROOT/firmware/ipodnano_fw_backup.bin" "${2:-$ROOT/firmware/ipodnano_fw_patched.bin}"
