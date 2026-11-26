# Roadmap

Features still to build, most important first. Every item follows the same rules as the existing
patches: exact original bytes plus enough context to reject other firmware builds, a build that
only changes what it says, and a test on a real device before it is marked done.

## 1. Custom boot logo on the iPod Video (5th gen)

**Goal:** `python3 scripts/patch.py --5g --logo-image FILE.bmp` (and `keep`), and Option-click on
the logo switch in the app, just like on the iPod photo.

**Where it stands**
- The boot logo is iPodWizard picture index 417, in the encrypted `aupd` image (partition
  `0xC3A400`, `0x106400` bytes). Flip/unflip works (`--5g --logo`, tested on a device), but only by
  swapping between two exactly known byte sequences (`scripts/patchdata/5g_logo.xor`).
- The encryption works byte by byte, by position: changing a pixel changes only the bytes at that
  position. But the logo data doesn't have a fixed row length: in the stock/flipped diff the rows
  are 120–124 bytes apart. So the picture is probably **compressed** (run-length encoded?) before
  it is encrypted. The cipher may still be a position XOR, as on the photo.
- The photo's keystream can't be reused: it looks random and covers other aupd offsets
  (photo `0xB5CB4`…, Video `0xBFA5C`…).
- Unknown: the compression format, the keystream for the logo area, how the aupd checksum
  (`0x426C`) is calculated, and the meaning of the field at `0x4274`, which iPodWizard changes from
  `ffffffff` to `10000000`.

**What's needed (from iPodWizard, on the user's iPod Video)**
1. Apple's logo (picture 417) exported as a BMP, with the size and colour depth iPodWizard shows.
2. A dump with a **solid-colour** logo on, plus that BMP (`ipod-solid.bin`).
3. A dump with a **noisy, random-pixel** logo on, plus that BMP (`ipod-noise.bin`).

The dumps are read-only reads by the Clickwheel app into
`~/Library/Application Support/Clickwheel/iPod-5g/`.

**Plan**
1. Work out the compression from the solid picture (long runs make the format show).
2. Recover the keystream from the noisy picture (little compression, so the most key bytes) and
   check it against the stock and flipped dumps.
3. Work out the aupd checksum (on the photo it is the byte sum of the decrypted aupd) and the
   `0x4274` field.
4. Add a `cipher` patch for the 5G that compresses, encrypts and stays inside the original logo's
   length (or proves that a longer one is safe). States `original`/`applied`/`custom`; Apple's logo
   is saved to `originals/5g-logo.bin` first.
5. Reproduce iPodWizard's dumps byte for byte, then test on the device, both ways.
6. Enable Option-click for the iPod Video in the app.

## 2. Device tests for the custom "Do not disconnect" picture

`--dnd` is built and checked on copies (on, then off, gives the original dump byte for byte) for the
iPod photo and the iPod Video, but neither has been tried on an iPod yet. Test on both, then mark
them tested in `CLAUDE.md` and `README.md`.

## 3. Custom renames

`--rename OLD=NEW` for any English menu string that fits its slot (same length or shorter), with
the same content checks. `--find TEXT` already shows how many bytes each slot allows. In the app:
a list of renames you can edit.

## 4. Patch catalogue as data

One file per model/firmware (offsets, original bytes, context, pictures) instead of the `MODELS`
table in `scripts/patch.py`, so a new firmware build is a data change, not a code change.

## 5. More browse orders

For example Label → Albums, or Composer → Albums. The method is in `docs/REVERSE_ENGINEERING.md`
(script VM, handler functions, global name = base + function index).

## 6. Other languages

The renames only touch the English UI block. The other language blocks need their own offsets and
wording.

## 7. Read-only resource viewer

Browse a firmware's strings, then its pictures (the 4G/photo and 5G picture header formats are
known) and fonts, without changing anything. A base for choosing what to customise next.

## 8. Research: 4th gen boot logo and pictures

Flipping the 4G's grey 84×100 apple in osos did not change the boot logo (tested), so the 4G's
boot logo lives elsewhere, probably in the flash bootloader. Also check whether the 4G has a
"Do not disconnect" picture in osos that `--dnd` could replace (it would be greyscale, 2 bits per
pixel).

## 9. More models and firmware builds

Other iPod Video firmware builds, the 5.5G, and later models. Each one is a separate port, done
with the gated process in `CLAUDE.md`.
