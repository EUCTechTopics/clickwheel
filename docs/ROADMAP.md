# Roadmap

Features still to build, most important first. Every item follows the same rules as the existing
patches: exact original bytes plus enough context to reject other firmware builds, a build that
only changes what it says, and a test on a real device before it is marked done.

## 1. Custom boot logo on the iPod Video (5th gen): built, device test pending

aupd turned out to be RC4 with the key in its security block, so no iPodWizard dumps were needed
(see `docs/REVERSE_ENGINEERING.md`). `--5g --logo-image FILE.bmp` (62×78) and Option-click in the
app are built and checked on copies (2026-11-27). Left: test on the device, then mark it tested.

## 2. Remove the volume limit on the iPod Video (5th gen): done, tested on a device

**Done 2026-11-27:** `--5g --volume` and the app switch, checked on copies (2 bytes change, the
checksum stays the same, off again gives the input byte for byte) and tested on the user's iPod
Video: the volume limit is gone.

**Goal:** `python3 scripts/patch.py --5g --volume` and a switch in the app: the iPod's built-in
maximum volume limit (the European one) is switched off, so Settings → Volume Limit can go to the
top. Source: a community HxD guide (search the disk for `08009fe5940090e5`, take the second hit,
swap the bytes `01 00` at its end to `00 01`).

**What the guide's edit is (static analysis of the user's dump, read-only, 2026-11-27)**
- The pattern occurs twice in osos (and twice in the hibernation image, a RAM copy). The guide's
  second hit is a 4-instruction function at osos `0xA0348` (partition `0xA4948`):
  ```
  ldr r0, =0x108710DC     ; 08 00 9F E5   a settings/region object
  ldr r0, [r0, #0x94]     ; 94 00 90 E5   its flags word
  and r0, r0, #1          ; 01 00 00 E2   -> returns bit 0: "volume is capped"
  bx  lr                  ; 1E FF 2F E1
  ```
  It has 2 callers. The first hit (osos `0x9F0F8`) reads the same word with `and r0, r0, #6`
  (another flag, 1 caller): the guide rightly skips it.
- The swap turns `01 00 00 E2` into `00 01 00 E2` = `and r0, r0, #0` (immediate 0 rotated): the
  function always returns 0. Nothing else changes.
- The HxD guide doesn't update the osos checksum; `patch.py` does, as for every patch.
- Same function on the iPod photo and the 4G: not found with this byte pattern; to research
  separately (they may have no such limit, or a differently compiled check).

**Plan**
1. Add patch `volume` to the 5G entry in `MODELS`: edit at partition `0xA4950`, `01 00` → `00 01`,
   with context = the whole function plus its literal (`08009fe5 940090e5` before,
   `00e2 1eff2fe1 dc108710` after), so other builds are rejected. Add `--volume`, `--check` state.
2. App: a sixth switch for the iPod Video ("Remove the volume limit"), with a short warning that
   high volume can damage hearing.
3. Docs: README table and "What the patches change", CLAUDE.md patch list, REVERSE_ENGINEERING.md.
4. Test on copies (on → off gives the input byte for byte), then on the device: write, restart
   with Menu + Select (so the hibernation image isn't resumed), Settings → Volume Limit to the top,
   and check, starting at low volume, that the maximum is louder than before. Then switch it off and
   check the limit is back.

Open question: whether bit 0 is set on this iPod at all (only European units have the cap). If the
user's iPod already goes to full volume, the patch is harmless but has no visible effect.

## 3. Device tests for the custom "Do not disconnect" picture

`--dnd` is built and checked on copies (on, then off, gives the original dump byte for byte) for the
iPod photo and the iPod Video, but neither has been tried on an iPod yet. Test on both, then mark
them tested in `CLAUDE.md` and `README.md`.

## 4. Custom renames

`--rename OLD=NEW` for any English menu string that fits its slot (same length or shorter), with
the same content checks. `--find TEXT` already shows how many bytes each slot allows. In the app:
a list of renames you can edit.

## 5. Patch catalogue as data

One file per model/firmware (offsets, original bytes, context, pictures) instead of the `MODELS`
table in `scripts/patch.py`, so a new firmware build is a data change, not a code change.

## 6. More browse orders

For example Label → Albums, or Composer → Albums. The method is in `docs/REVERSE_ENGINEERING.md`
(script VM, handler functions, global name = base + function index).

## 7. Other languages

The renames only touch the English UI block. The other language blocks need their own offsets and
wording.

## 8. Read-only resource viewer

Browse a firmware's strings, then its pictures (the 4G/photo and 5G picture header formats are
known) and fonts, without changing anything. A base for choosing what to customise next.

## 9. Research: 4th gen boot logo and pictures

Flipping the 4G's grey 84×100 apple in osos did not change the boot logo (tested), so the 4G's
boot logo lives elsewhere, probably in the flash bootloader. Also check whether the 4G has a
"Do not disconnect" picture in osos that `--dnd` could replace (it would be greyscale, 2 bits per
pixel).

## 10. More models and firmware builds

Other iPod Video firmware builds, the 5.5G, and later models. Each one is a separate port, done
with the gated process in `CLAUDE.md`.
