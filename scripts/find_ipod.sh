#!/bin/zsh
# Read-only: find the firmware partition (Apple_MDFW) of a connected, Mac-formatted iPod.
# Prints the partition identifier (e.g. disk6s2) on stdout; diagnostics go to stderr.
# Usage: scripts/find_ipod.sh            -> auto-detect (fails unless exactly one match)
#        scripts/find_ipod.sh disk6s2    -> validate the given partition instead
set -euo pipefail
EXPECTED=33554432

check_part() {
  local part=$1 disk=${1%s*}
  diskutil info "$disk" 2>/dev/null | grep -q "Media Name:.*iPod" || { echo "error: $disk is not an iPod" >&2; return 1; }
  diskutil info "$part" 2>/dev/null | grep -q "Partition Type:.*Apple_MDFW" || { echo "error: $part is not an Apple_MDFW firmware partition" >&2; return 1; }
  diskutil info "$part" | grep -q "($EXPECTED Bytes)" || { echo "error: $part is not $EXPECTED bytes" >&2; return 1; }
}

if [[ $# -ge 1 ]]; then
  check_part "$1"; echo "$1"; exit 0
fi

parts=(${(f)"$(diskutil list external | awk '/Apple_MDFW/ {print $NF}')"})
parts=(${parts:#})
if (( ${#parts} == 0 )); then
  echo "error: no Apple_MDFW partition found. Is the iPod connected, and is it Mac-formatted?" >&2
  echo "       (Windows-formatted iPods use a different layout and are not supported.)" >&2
  exit 1
elif (( ${#parts} > 1 )); then
  echo "error: several firmware partitions found (${parts[*]}); pass one explicitly." >&2
  exit 1
fi
check_part "${parts[1]}"
echo "${parts[1]}"
