---
description: Guide me through safely patching my iPod firmware (Genres → Labels, Labels → Composers, Composers → Producers)
---

Walk me through patching my iPod with this repository, following the workflow and hard rules in
`CLAUDE.md` exactly:

1. Start read-only with `scripts/ipod_info.sh` and confirm the device with me.
2. Have me run the backup myself (`! sudo scripts/backup_fw.sh`) and check that it was verified.
3. Run `python3 scripts/patch.py --check`, then show me the patch plan and wait for my "yes".
4. Build the patched copy and check that only the planned bytes changed.
5. Explain recovery, then have me run the write myself and tell me how to reboot and what to test.

Go one step at a time and wait for me between steps. $ARGUMENTS
