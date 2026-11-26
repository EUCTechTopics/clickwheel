# CLAUDE.md: guide for Claude Code in this repository

This repo patches the Apple firmware of click-wheel iPods. It supports three models:

- **iPod 4th generation** (click wheel, "iPod Q21") with firmware 3.1.1: **tested on a device**.
- **iPod Video (5th generation)**, one firmware build (`osos` 0x735A00 bytes): **tested on a device**.
- **iPod photo / iPod color** ("iPod P98") with firmware 1.2.1 (buildID 4.2.1): **tested on a device**
  (MA079, all three patches).

The patches, available on all models, are:

1. `--labels`: the English menu label **Genres** becomes **Labels**.
2. `--composers`: picking a genre/label shows **Composers** instead of **Artists**
   (Label → Composers → Albums → Songs).
3. `--producers`: the English menu label **Composers** becomes **Producers** (for people who
   store the producer in the Composer tag).

The user typically just cloned the repo and says something like "patch my iPod". Walk them
through the workflow below, one stage at a time. The user may not be technical. Explain each
step in plain words, say what it touches, and wait for an explicit "yes" before any step that
changes something.

## Hard rules

- **Read-only first.** Identify the device before anything else. Never guess disk numbers.
- **Never write to the iPod yourself.** All `sudo` steps (`backup_fw.sh`, `write_fw.sh`,
  `rollback_fw.sh`) are run **by the user**, by typing `! sudo scripts/<script>` in the Claude
  Code prompt. You can't enter their password, and device writes must stay their decision.
  Never run `dd`, `diskutil eraseDisk/partitionDisk`, or anything else that writes to `/dev/*`.
- **Never modify or delete `firmware/ipod_fw_backup.bin`, `firmware/ipod5g_fw_backup.bin` or
  `firmware/ipodphoto_fw_backup.bin`**, or their `.sha256` files. They're the only way back.
- **Patch copies only.** `scripts/patch.py` writes a new file and refuses to overwrite. Don't
  bypass its checks, and don't hand-edit firmware bytes outside it.
- **Unsupported device or firmware → stop.** If the iPod is not a 4G (`iPod Q21`, 3.1.1), an
  iPod photo (`iPod P98`, buildID 4.2.1) or an iPod Video whose dump passes `patch.py --5g --check`, if it's Windows-formatted (no
  `Apple_MDFW` partition), or if `--check` reports `mismatch`, explain that the patch doesn't
  apply and don't continue. Offsets are
  firmware-specific. Porting is possible (see `docs/REVERSE_ENGINEERING.md`), but only as a
  separate, explicitly requested analysis that follows the same gated process.
- **Report honestly.** Show the script output that matters (sizes, hashes, `OK:` lines). If
  something fails, say so and stop.

## Workflow

### 1. Identify (read-only)
Run `scripts/ipod_info.sh`. Confirm with the user:
- the firmware partition (e.g. `disk6s2`, type `Apple_MDFW`, 33,554,432 bytes),
- `BoardHwName: iPod Q21` and `buildID ... (3.1.1)` from SysInfo.

`ipod_info.sh` prints the detected model. `BoardHwName: iPod P98` with `buildID ... (4.2.1)` is an
**iPod photo**: continue with the iPod photo workflow at the end of this file (the 4G scripts refuse it).

If `ipod_info.sh` reports a partition that isn't 33,554,432 bytes, check with
`diskutil list external` and `diskutil info diskNs2`. A **67,108,864-byte** `Apple_MDFW` partition
means an iPod Video (5G), whose SysInfo may be empty. Continue with the 5G workflow at the end of
this file.

If SysInfo isn't shown, the data volume isn't mounted. Ask the user to reconnect the iPod or
mount it in Finder. If there are several iPods, ask which partition to use and pass it to every
script. **Ask for confirmation before continuing.**

### 2. Back up (user runs it)
Skip if `firmware/ipod_fw_backup.bin` already exists and the user confirms it came from **this**
iPod (check with `cd firmware && shasum -a 256 -c ipod_fw_backup.bin.sha256`).
Otherwise ask the user to run:
```
! sudo scripts/backup_fw.sh
```
It unmounts the iPod, reads the partition twice, compares the hashes and ends with
`OK: backup verified`. Don't continue without that line.

### 3. Check
```
python3 scripts/patch.py --check
```
Every patch must report `original` (or `applied` if the device was already patched). Any
`mismatch` → stop (see the hard rules).

### 4. Plan and confirm
Ask which patches they want: any combination of `--labels`, `--composers` and `--producers`.
`--labels --composers` is the usual choice. Add `--producers` if they keep the producer in the
Composer tag. Show
the plan: the offsets and old/new bytes from the table in `README.md` ("What the patches
change"), plus the new osos checksum. **Wait for confirmation.**

### 5. Build the patched copy
```
python3 scripts/patch.py --labels --composers      # or a subset
```
This writes `firmware/ipod_fw_patched.bin` (+ `.sha256`) and prints every changed byte. Check
that the changed bytes are exactly the planned ones and that the checksum line is printed.
If the output file exists, ask before choosing a new name with `-o`. Never delete the old one
without asking.

### 6. Write (user runs it, after confirming)
Explain that this is the step that changes the iPod, then ask the user to run:
```
! sudo scripts/write_fw.sh firmware/ipod_fw_patched.bin
```
It must end with `OK: firmware partition now matches ...`. On `READBACK MISMATCH`: tell the user
**not to unplug** and to run `! sudo scripts/rollback_fw.sh`.

### 7. Reboot and test
Tell the user to:
1. `diskutil eject diskN`, then unplug.
2. Hold **Menu + Select** until the Apple logo appears.
3. Check Music → **Labels**, pick a label, and confirm they see that label's composers, then
   albums, then songs. Also check that Music → Artists and Music → Composers still behave
   normally. With `--producers`, the Composers menu and "All Composers" now read **Producers**.

### Recovery (tell the user this before step 6)
- Undo: `! sudo scripts/rollback_fw.sh` writes the original backup back.
- iPod doesn't boot: **disk mode**. Hold Menu + Select to reset. As soon as the Apple logo
  appears, switch to holding **Select + Play** until "Do not disconnect" appears. Connect it and
  run the rollback.
- Last resort: restore in Finder/iTunes. That reinstalls stock firmware and **erases the
  music**. iFlash-modded iPods can have trouble with restores.
- A Finder/iTunes firmware update or restore removes the patches. Re-run the workflow.

### iPod Video (5th gen)
Same workflow and the same rules, with these differences:

- The scripts take the partition explicitly (no auto-detect), so confirm it first.
- Back up: `! sudo scripts/backup_fw_5g.sh diskNs2` → `firmware/ipod5g_fw_backup.bin`.
- Check / build: `python3 scripts/patch.py --5g --check`, then
  `python3 scripts/patch.py --5g --labels --composers [--producers]` → `firmware/ipod5g_fw_patched.bin`.
- Write: `! sudo scripts/write_fw_5g.sh diskNs2`. It writes only the 512-byte sectors that differ
  (the partition also holds a hibernation image, which must be left alone).
- Undo: `! sudo scripts/rollback_fw_5g.sh diskNs2`.
- Reboot and test as for the 4G.

### iPod photo / iPod color
Same workflow and the same rules. The 4G scripts refuse an iPod photo (same 32 MiB partition), so:

- Confirm `BoardHwName: iPod P98` and `buildID ... (4.2.1)` (shown as 1.2.1), and the partition.
- Back up: `! sudo scripts/backup_fw_photo.sh diskNs2` → `firmware/ipodphoto_fw_backup.bin`.
- Check / build: `python3 scripts/patch.py --photo --check` (it also says whether the `osos` image is
  identical to Apple's stock 1.2.1 image), then
  `python3 scripts/patch.py --photo --labels --composers [--producers]` → `firmware/ipodphoto_fw_patched.bin`.
- Write: `! sudo scripts/write_fw_photo.sh diskNs2` (only the differing 512-byte sectors).
- Undo: `! sudo scripts/rollback_fw_photo.sh diskNs2`.
- Reboot and test as for the 4G.

### The Clickwheel app (GUI)
`app/` holds a native macOS app (SwiftUI) that runs the same scripts: `app/build_app.sh`, then
`open app/build/Clickwheel.app`. It only does read-only work by itself; backup, write and rollback
open a Terminal window running the `sudo scripts/…` command (after a confirmation dialog), where the
user types their password. (Starting the scripts through `osascript … with administrator privileges`
fails: macOS blocks raw disk access for them with "Operation not permitted".)
If the user prefers the app, explain that, and don't run it to change anything for them.

## Repository map

| Path | What it is |
|---|---|
| `scripts/ipod_info.sh` | Read-only overview: disks, firmware partition, SysInfo |
| `scripts/find_ipod.sh` | Read-only: finds/validates the `Apple_MDFW` partition (used by the other scripts) |
| `scripts/backup_fw.sh` | sudo: dumps the partition to `firmware/ipod_fw_backup.bin`, reads twice and compares |
| `scripts/patch.py` | Builds patched copies; `--check` to inspect. Content-based safety checks. |
| `scripts/write_fw.sh` | sudo: writes an image (checks its `.sha256`, partition type and size), reads it back |
| `scripts/rollback_fw.sh` | sudo: writes the original backup back |
| `scripts/backup_fw_5g.sh`, `write_fw_5g.sh`, `rollback_fw_5g.sh` | sudo, iPod Video 5G (`--5g`): backup; write/undo only the differing sectors (leaves the hibernation image alone) via `write_sectors.py` |
| `scripts/backup_fw_photo.sh`, `write_fw_photo.sh`, `rollback_fw_photo.sh` | sudo, iPod photo (`--photo`): same approach as the 5G scripts |
| `scripts/ipod_model.sh` | Read-only: `4g`, `5g`, `photo` or `unknown` for a partition (SysInfo, else size); the sudo scripts refuse a mismatch |
| `scripts/same_model.py` | Read-only: refuses a full-partition write (4G) when the device holds a different model's firmware |
| `app/` | Clickwheel, the macOS GUI (SwiftUI). `app/build_app.sh` builds `app/build/Clickwheel.app` |
| `firmware/` | Firmware dumps and outputs. Git-ignored: contains Apple's firmware, never commit it. |
| `docs/REVERSE_ENGINEERING.md` | How the patches were found; offsets and structures for extending them |

## Extending

To find strings for a new rename, use the read-only `python3 scripts/patch.py [--5g] --find "Text"`.
It lists every occurrence with context and how many bytes each slot allows. Only rename the
English UI block (where the existing rename offsets are), with the same length or shorter.
`python3 scripts/patch.py --photo --plan --json --labels` shows a build as JSON without writing
(the app uses this). To add a patch, add an entry to the model's `patches` in `MODELS` (`scripts/patch.py`) with exact original bytes and
enough surrounding context to reject other firmware builds, and document it in `README.md`.
Background (script VM, method descriptors, category numbers, handler functions) is in
`docs/REVERSE_ENGINEERING.md`. Only change behaviour that can be verified statically, and ask the
user to test on the device.
