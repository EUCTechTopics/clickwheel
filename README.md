# Clickwheel

> Firmware patches for **click-wheel iPods** (the **iPod 4th generation**, the **iPod photo / color**
> and the **iPod Video (5th generation)**) that turn the *Genres* menu into a **Labels** browser.
> Use the native **Clickwheel** Mac app, or let **Claude Code** guide you step by step.

![iPod 4G](https://img.shields.io/badge/iPod%204G-tested%20on%20device-brightgreen)
![iPod Video 5G](https://img.shields.io/badge/iPod%20Video%205G-tested%20on%20device-brightgreen)
![iPod photo](https://img.shields.io/badge/iPod%20photo-tested%20on%20device-brightgreen)
![platform](https://img.shields.io/badge/host-macOS-black)
![claude code](https://img.shields.io/badge/guided%20by-Claude%20Code-d97757)
![license](https://img.shields.io/badge/license-MIT-green)

If you use the iPod's *Genre* tag for the **record label**, this makes the menus match:

| | Stock firmware | Patched |
|---|---|---|
| Menu name | Music → **Genres** | Music → **Labels** |
| After picking an entry | Genre → **Artists** → Albums → Songs | Label → **Composers** → Albums → Songs |
| Composers menu (optional) | Music → **Composers** | Music → **Producers** |

The Composers step pairs well with writing only the *main* artist into the **Composer** tag. That
keeps a label's list clean even when tracks credit several artists. If you use that tag for the
**producer** instead, `--producers` renames the menu to match, so the path reads
Label → Producers → Albums → Songs.

All patches are tiny in-place byte changes, and you can pick any combination:

| Flag | What it does | Size |
|---|---|---|
| `--labels` | *Genres* → *Labels* (English menus) | 5 strings |
| `--composers` | Picking a label shows Composers instead of Artists | 1 byte |
| `--producers` | *Composers* → *Producers* (English menus) | 5 strings |
| `--logo` | iPod photo / color and iPod Video: the boot Apple logo upside down (it lives in the `aupd` image; tested on both) | 15,600 / 9,552 bytes |
| `--logo-image FILE.bmp` | iPod photo / color (78×100 BMP) and iPod Video (62×78 BMP), both tested on a device: your own boot logo instead of the flipped Apple. Apple's logo is saved first (`originals/`), so switching it off puts it back | 15,600 / 9,672 bytes |
| `--dnd FILE.bmp` | iPod photo / color and iPod Video: your own *Do not disconnect* picture (100×100 BMP, 16- or 24-bit). Apple's original is saved next to the input (`originals/`) first, so switching it off puts it back | 20,000 bytes |
| `--volume` | All models: removes the built-in (European) volume limit; then raise Settings → Volume Limit. Tested on a device on the iPod Video and the 4G; the photo is untested (needs a European unit: US iPods have no cap). Loud music can damage your hearing | 2 bytes |

The image checksum is recalculated in every case.

---

## ⚠️ Read this first

- This writes to your iPod's **firmware partition**. Every step makes or checks a verified backup
  first, and the original can be written back at any time. You still use it **at your own risk**.
- This repo contains **no Apple firmware**. Everything is dumped from *your* iPod into `firmware/`,
  which is git-ignored. Don't commit or share those files.
- Read [Recovery](#recovery) before you write anything.

## Compatibility

| | iPod 4th generation | iPod photo / iPod color | iPod Video (5th generation) |
|---|---|---|---|
| Status | **Tested on a device** | **Tested on a device** (MA079) | **Tested on a device** |
| Identify | `BoardHwName: iPod Q21` (tested: M9282) | `BoardHwName: iPod P98` (e.g. MA079) | 64 MiB `Apple_MDFW` firmware partition |
| Firmware | Apple **3.1.1** | Apple **1.2.1** (buildID 4.2.1) | The build whose `osos` image is `0x735A00` bytes (checked by `--check`) |
| Patch flag | (default) | `--photo` | `--5g` |
| Scripts | `backup_fw.sh`, `write_fw.sh`, `rollback_fw.sh` | `backup_fw_photo.sh`, `write_fw_photo.sh`, `rollback_fw_photo.sh` | `backup_fw_5g.sh`, `write_fw_5g.sh`, `rollback_fw_5g.sh` |
| Storage mods | Works with iFlash (tested) | Not tested | Not tested |

On all models:

| | |
|---|---|
| Format | **Mac-formatted** iPod (has an `Apple_MDFW` firmware partition). Windows-formatted iPods aren't supported. |
| Host | macOS with `zsh` and Python 3 (standard library only) |
| Menu language | **English**. Other languages are left as they are. |
| Patches | `--labels`, `--composers`, `--producers` and `--volume`, in any combination (plus pictures on the photo and Video) |

The patcher checks the firmware's **content**: structure, image size, checksum, and the exact
original bytes plus surrounding context at every patch location. On anything else (another
firmware version, another model, a corrupt dump) it stops without writing.

---

## The Clickwheel app

A native macOS app (SwiftUI, macOS 14+) for people who'd rather not use the command line. One
window per iPod, like Finder's device page: the three changes as switches, an animated iPod that
shows the result, and an **Apply** button. Switching everything off puts Apple's original menus back.

```sh
app/build_app.sh                 # needs Xcode or the Command Line Tools (swift)
open app/build/Clickwheel.app
```

- **Apply** asks for your Mac password once (macOS's own dialog, `/usr/libexec/authopen`), which
  gives Clickwheel a handle to the firmware partition and nothing else. The app never sees your
  password and nothing runs as root. Then it:
  1. checks the iPod and unmounts it (`scripts/write_fd.py prepare`);
  2. reads the firmware partition twice and compares (`scripts/backup_fd.py dump`);
  3. builds your selection from that read with `patch.py --exact`;
  4. writes only the sectors that differ, inside the osos area, and reads them back
     (`scripts/write_fd.py write`, via `write_sectors.apply`). The iPod must still hold what was read.
- **No safety copy in the repository.** The app keeps the iPod's firmware, as last read or written
  and verified, in `~/Library/Application Support/Clickwheel/<serial>/ipod.bin`. Undo means switching
  everything off: `patch.py` holds the original bytes of every change, and for the iPod photo the
  result is checked against Apple's original software. If a write is interrupted, the image is kept
  as `pending.bin` and the next Apply finishes it.
- **Check** (Details ▸ Read from iPod) reads the iPod the same way and shows which changes are on it.
- Why `authopen`: macOS blocks raw disk access (`dd: /dev/rdiskNs2: Operation not permitted`) for
  commands an app starts with `do shell script … with administrator privileges`, even with Full
  Disk Access. `authopen` is Apple's own tool for opening a device after a password prompt.
- The first time, macOS asks whether Clickwheel may read files on a removable volume. That's for
  `iPod_Control/Device/SysInfo` (model and firmware version).
- **Details & Log** (⌘I, or the ⓘ button) has the technical view: device facts, the firmware copy on
  this Mac, the byte-level diff, partition map and new checksum, and the log of every command (also
  in `~/Library/Logs/Clickwheel.log`).
- The `sudo scripts/*.sh` commands (with their safety copies in `firmware/`) stay available for
  working in Terminal.

## Quick start with Claude Code

```sh
git clone https://github.com/EUCTechTopics/clickwheel.git
cd clickwheel
claude
```

Then type:

```
/patch-ipod
```

(or just say *"patch my iPod"*). Claude Code reads [`CLAUDE.md`](CLAUDE.md) and walks you through:

1. **Identify:** finds the iPod and checks the model and firmware (read-only).
2. **Back up:** *you* run `! sudo scripts/backup_fw.sh`. Claude never handles your password.
3. **Check and plan:** shows exactly which bytes will change and waits for your "yes".
4. **Build:** creates a patched **copy** and checks that only the planned bytes changed.
5. **Write:** *you* run `! sudo scripts/write_fw.sh firmware/ipod_fw_patched.bin`.
6. **Reboot and test:** explains how to restart the iPod and what to check.

The project's `.claude/settings.json` blocks Claude from running `sudo`, `dd` or disk-erasing
commands itself. The steps that change your device are always yours to run.

## Manual usage

```sh
scripts/ipod_info.sh                                   # 1. identify (read-only)
sudo scripts/backup_fw.sh                              # 2. backup -> firmware/ipod_fw_backup.bin
python3 scripts/patch.py --check                       # 3. inspect: every patch should say "original"
python3 scripts/patch.py --labels --composers          # 4. build firmware/ipod_fw_patched.bin (add --producers if wanted)
sudo scripts/write_fw.sh firmware/ipod_fw_patched.bin  # 5. write + read back and compare
diskutil eject diskN                                   # 6. unplug, hold Menu + Select to reboot
```

On an **iPod Video (5th gen)**, use the `--5g` flag and the `_5g` scripts. They take the
firmware partition explicitly (find it with `diskutil list external`):

```sh
sudo scripts/backup_fw_5g.sh diskNs2                   # backup -> firmware/ipod5g_fw_backup.bin
python3 scripts/patch.py --5g --check
python3 scripts/patch.py --5g --labels --composers     # -> firmware/ipod5g_fw_patched.bin (add --producers if wanted)
sudo scripts/write_fw_5g.sh diskNs2                    # writes only the sectors that differ
```

On an **iPod photo / iPod color** (firmware 1.2.1), use `--photo` and the `_photo` scripts:

```sh
sudo scripts/backup_fw_photo.sh diskNs2                # backup -> firmware/ipodphoto_fw_backup.bin
python3 scripts/patch.py --photo --check
python3 scripts/patch.py --photo --labels --composers  # -> firmware/ipodphoto_fw_patched.bin
sudo scripts/write_fw_photo.sh diskNs2                 # writes only the sectors that differ
```

**Removing patches.** A normal build only adds patches. With `--exact`, the patches you name are
applied and every other patch is put back to its original bytes. This matters when your backup was
made from an iPod that was already patched (`--check` then says `applied`, and the rollback scripts
would restore those patches):

```sh
python3 scripts/patch.py --photo --exact --labels      # Labels only; Composers/Producers removed
python3 scripts/patch.py --photo --exact               # no patches at all
```

For the iPod photo, the build also says whether the result is identical to Apple's stock `osos`
image. Write the result with the usual write script. The Clickwheel app always builds with `--exact`.

The 4G scripts auto-detect the iPod's firmware partition. If more than one iPod is connected, pass
the partition explicitly, e.g. `sudo scripts/write_fw.sh firmware/ipod_fw_patched.bin disk6s2`.

---

## What the patches change

The tables below are for the **iPod 4th generation**; the 5G offsets follow in
[their own section](#ipod-video-5th-gen---5g). Offsets are into the 32 MiB `Apple_MDFW`
partition. The `osos` image (the main OS) starts at `0x4600`.

### `--labels`: rename *Genres* → *Labels*

`47 65 6E 72 65 73` ("Genres") → `4C 61 62 65 6C 73` ("Labels") at:

| Offset | Where it shows up |
|---|---|
| `0x1B7C3C` | Music menu item |
| `0x1B8248` | "All Genres" → "All Labels" |
| `0x1B95F2` | Main-menu settings checklist |
| `0x1B9788` | Main-menu item list |
| `0x1B9B4C` | Shuffle / settings list |

### `--composers`: *Labels* → **Composers**

| Offset | Old | New | Meaning |
|---|---|---|---|
| `0x1BF558` | `3B` | `23` | The genre handler calls *open Composers* (`0x823`) instead of *open Artists* (`0x83B`) |

### `--producers`: rename *Composers* → *Producers*

`Composers` → `Producers` (same length) at:

| Offset | Where it shows up |
|---|---|
| `0x1B7C44` | Music menu item |
| `0x1B822C` | "All Composers" → "All Producers" |
| `0x1B95E6` | Main-menu settings checklist |
| `0x1B977C` | Main-menu item list |
| `0x1B9B70` | Shuffle / settings list |

### `--volume`: no built-in volume limit

`0x7DFF0`: `01 00` → `00 01`. The volume-cap check (osos `0x799E8`) reads a flag that makes the
player's maximum volume 216 instead of 256; `and r0, r0, #1` becomes `and r0, r0, #0`, so it is
never capped. Two bytes swap places, so the checksum doesn't change. Only European iPods have the
flag set; on others the patch changes nothing you can hear. Tested on a device.

### Checksum

The `osos` checksum (32-bit sum of the image bytes) at **`0x421C`** is recalculated. Each
Labels string lowers it by `0x11` and each Producers string by `0x4`:

| Image | `osos` checksum |
|---|---|
| Stock 3.1.1 | `0x1259EF03` |
| `--labels` | `0x1259EEAE` |
| `--composers` | `0x1259EEEB` |
| `--labels --composers` | `0x1259EE96` |
| `--labels --composers --producers` | `0x1259EE82` |

### iPod Video (5th gen): `--5g`

All three patches, for the 5G build whose `osos` image is `0x735A00` bytes
(64 MiB partition, checksum `0x2C7C48F3` stock). Offsets are into the 64 MiB partition:

| Patch | Offset | Old | New |
|---|---|---|---|
| `--labels` | `0x4B5A04`, `0x4B6760`, `0x4B7FB6`, `0x4B8158`, `0x4B8818` | `Genres` | `Labels` |
| `--composers` | `0x4BEEFA` | `69` | `4C` (genre handler #248 calls *open Composers* `0x104C` instead of *open Artists* `0x1069`) |
| `--producers` | `0x4B5A0C`, `0x4B6744`, `0x4B7FA6`, `0x4B814C`, `0x4B884C` | `Composers` | `Producers` |
| `--volume` | `0xA4950` | `01 00` | `00 01` (the volume-cap check `and r0, r0, #1` becomes `#0`: never capped; checksum unchanged) |

Checksum with `--labels --composers`: `0x2C7C4881`. With all three: `0x2C7C486D` (at `0x421C`). The 5G partition also holds a
hibernation image, so 5G images are written with `write_fw_5g.sh`, which writes only the 512-byte
sectors that differ (all inside `osos`) and leaves the rest alone. Undo with
`sudo scripts/rollback_fw_5g.sh diskNs2`.

### iPod photo / iPod color: `--photo`

All three patches, for firmware 1.2.1 (`osos` image `0x523514` bytes, checksum `0x1DE43EC5` stock).
Offsets are into the 32 MiB partition:

| Patch | Offset | Old | New |
|---|---|---|---|
| `--labels` | `0x27176C`, `0x271D88`, `0x2735E2`, `0x2737C4`, `0x273DA0` | `Genres` | `Labels` |
| `--composers` | `0x27A088` | `EC` | `D1` (genre handler #281 calls *open Composers* `0x9D1` instead of *open Artists* `0x9EC`) |
| `--producers` | `0x271774`, `0x271D6C`, `0x2735D2`, `0x2737B8`, `0x273DD4` | `Composers` | `Producers` |
| `--volume` | `0x87880` | `01 00` | `00 01` (the volume-cap check `and r0, r0, #1` becomes `#0`: never capped; checksum unchanged) |

Checksums: `--labels` `0x1DE43E70`, `--composers` `0x1DE43EAA`, `--labels --composers`
`0x1DE43E55`, all three `0x1DE43E41`. These offsets were found in Apple's own 1.2.1 updater image; all three
patches together were confirmed on a device (MA079). `--check` verifies every byte against *your*
backup first.

## How it works

On all three models, the UI is partly written as **bytecode for a small JavaScript-style VM**
inside the firmware. The 5G and the iPod photo use the same VM, with their tables at different offsets. Each browse category has its own small script handlers. When you pick a genre, the
handler records the selection and then calls a global "open Artists list" function. Patch 2
points that call at the "open Composers list" function instead. The composer list is built with
the same library query as the artist list, and picking a composer keeps the genre selected, so
you only see the label's composers.

The full notes (memory map, native method binding, category numbers, script function table)
are in [`docs/REVERSE_ENGINEERING.md`](docs/REVERSE_ENGINEERING.md).

---

## Recovery

| Situation | What to do |
|---|---|
| Undo everything | `sudo scripts/rollback_fw.sh` (5G: `sudo scripts/rollback_fw_5g.sh diskNs2`) writes your original backup back |
| Different set of patches | Build the set you want (with `-o` for a new file name) and write it |
| iPod doesn't boot (Apple logo, folder icon, reboot loop) | **Disk mode:** hold *Menu + Select* to reset. As soon as the Apple logo appears, switch to holding *Select + Play* until "Do not disconnect" appears. Connect it and run the rollback. |
| Nothing else works | Restore in Finder/iTunes. This reinstalls stock firmware but **erases the music**. iFlash-modded iPods sometimes need extra steps; check iFlash's documentation. |

A Finder/iTunes **firmware update or restore** removes the patches. Just run the workflow again.

## Repository layout

```
.
├── CLAUDE.md                 # step-by-step workflow and safety rules for Claude Code
├── .claude/
│   ├── commands/patch-ipod.md  # the /patch-ipod command
│   └── settings.json           # allows read-only checks, blocks sudo/dd for Claude
├── scripts/
│   ├── ipod_info.sh          # read-only: disks, firmware partition, model/firmware
│   ├── find_ipod.sh          # read-only: locate/validate the Apple_MDFW partition
│   ├── backup_fw.sh          # sudo: dump the partition (read twice and compare)
│   ├── patch.py              # build patched copies; --check to inspect
│   ├── write_fw.sh           # sudo: write an image, read it back and compare
│   ├── rollback_fw.sh        # sudo: write the original backup back
│   ├── *_5g.sh               # sudo: iPod Video backup / write / rollback
│   ├── *_photo.sh            # sudo: iPod photo backup / write / rollback
│   ├── ipod_model.sh         # read-only: which model is this partition?
│   ├── device_state.sh       # sudo, read-only: which patches are on the iPod now?
│   ├── same_model.py         # read-only: device and image are the same model (4G write)
│   ├── library.py            # read-only: the iPod's music per label, for the app's preview
│   └── write_sectors.py      # helper: write only the sectors that differ (5G, photo)
├── app/                      # Clickwheel.app (SwiftUI); build with app/build_app.sh
├── docs/REVERSE_ENGINEERING.md
└── firmware/                 # your dumps and outputs (git-ignored)
```

## Roadmap: a light, modern iPodWizard for Mac

[iPodWizard](https://en.wikipedia.org/wiki/IPodWizard) let Windows users edit iPod firmware
resources. This project aims for a smaller, safer take on that idea for macOS: verified backups,
content-checked patches, and Claude Code as the guide.

- [x] Verified backup / write / rollback for the 4G and the iPod Video (5G), both tested on a device
- [x] Menu renames: Genres → Labels, Composers → Producers
- [x] Browse-order change: Label → Composers
- [x] `patch.py --find TEXT`: read-only string search showing how many bytes each slot allows
- [x] iPod photo / color (1.2.1) port, tested on a device
- [x] Native Mac app (Clickwheel.app) with diff view, partition map and live menu preview
- [x] Boot logo upside down on the iPod photo and the iPod Video; your own boot logo on the iPod photo
- [x] Your own "Do not disconnect" picture on the iPod photo and the iPod Video (not yet tested on a device)
- [x] Your own boot logo on the iPod Video (tested on a device)
- [ ] **Custom renames:** `--rename OLD=NEW` for any English menu string that fits its slot,
      with the same content checks
- [ ] Patch catalogue as data (one file per model/firmware) instead of code
- [ ] Other languages
- [ ] More browse orders (e.g. Label → Albums)
- [ ] Read-only viewer for firmware resources (strings, then images and fonts)

Details, status and what's needed for each item: [`docs/ROADMAP.md`](docs/ROADMAP.md).

Contributions are welcome. Every new patch needs exact original bytes plus enough context to
reject other firmware builds, and a test on a real device.

## Limitations

- English menus only. Other languages still say "Genres" (and "Composers").
- The Label → Composer path never existed in Apple's firmware. The main path (label → its
  composers → albums → songs) is confirmed on a device. "All" entries, screen titles and
  "what plays next" haven't been specifically tested yet.
- `--producers` only renames menu text; it uses the same mechanism as `--labels`, which is
  confirmed on a device.
- The 5G offsets were found on one 5G firmware build. Other 5G builds are rejected by `--check`.
- One firmware build per model: 3.1.1 on the 4G, 1.2.1 on the iPod photo and one 5G build. Porting to other versions
  means finding the offsets again. The notes explain the method.

## License

[MIT](LICENSE) © 2026 Mathijs de Ruiter. This covers the scripts and documentation in this
repository only, not Apple's firmware, which you dump from your own device and must not
redistribute.

## Acknowledgements

The image-directory layout (`]ih[` header, 40-byte entries) follows community documentation
from the iPodLinux and Rockbox projects. Disassembly was done with
[Capstone](https://www.capstone-engine.org/).

*Not affiliated with or endorsed by Apple. iPod is a trademark of Apple Inc.*
