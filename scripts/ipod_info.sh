#!/bin/zsh
# Read-only: show what is connected and whether it is a supported iPod/firmware.
set -uo pipefail
HERE=${0:A:h}
echo "== External disks"
diskutil list external
echo
PART=$("$HERE/find_ipod.sh" "$@") || exit 1
DISK=${PART%s*}
echo "== Firmware partition: /dev/$PART"
diskutil info "$PART" | grep -E "Partition Type|Disk Size"
echo
echo "== iPod SysInfo"
MNT=$(diskutil info "${DISK}s3" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
if [[ -n "${MNT:-}" && -f "$MNT/iPod_Control/Device/SysInfo" ]]; then
  grep -E "BoardHwName|ModelNumStr|buildID|visibleBuildID|HddFirmwareRev" "$MNT/iPod_Control/Device/SysInfo"
else
  echo "(data volume not mounted or SysInfo missing; mount it to see the model/firmware)"
fi
echo
echo "Supported: BoardHwName 'iPod Q21' (4th gen click wheel) with buildID 3.1.1."
