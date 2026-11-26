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
MODEL=$("$HERE/ipod_model.sh" "$PART")
case "$MODEL" in
  4g)    echo "Model: iPod 4th generation (iPod Q21). Supported with firmware 3.1.1; check with: python3 scripts/patch.py --check" ;;
  photo) echo "Model: iPod photo / iPod color (iPod P98). Supported with firmware 1.2.1 (buildID 4.2.1); check with: python3 scripts/patch.py --photo --check" ;;
  *)     echo "Model: not recognised from SysInfo." ;;
esac
echo
echo "Supported: 'iPod Q21' (4th gen) with 3.1.1, 'iPod P98' (photo/color) with 1.2.1 (buildID 4.2.1),"
echo "and the iPod Video (5G) build checked by patch.py --5g (64 MiB partition; see CLAUDE.md)."
