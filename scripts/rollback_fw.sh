#!/bin/zsh
# Restore the original, unmodified firmware from firmware/ipod_fw_backup.bin.
# Usage: sudo scripts/rollback_fw.sh [diskNsM]      (auto-detects the partition if omitted)
set -euo pipefail
ROOT=${0:A:h:h}
exec "$ROOT/scripts/write_fw.sh" "$ROOT/firmware/ipod_fw_backup.bin" "$@"
