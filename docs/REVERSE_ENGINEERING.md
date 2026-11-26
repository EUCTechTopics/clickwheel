# Reverse-engineering notes: iPod 4G firmware 3.1.1

How the two patches were found, and the structures you need to extend them. Offsets are into the
`osos` image unless marked *partition*. Partition offset = `osos` offset + `0x4600`.

## Firmware partition layout

| What | Where |
|---|---|
| Header magic `]ih[` | partition `0x100` |
| Directory offset / format version | partition `0x104` (u32 = `0x4000`), `0x10A` (u16 = 3) |
| Directory (format 3 adds `+0x200` to every offset) | partition `0x4200` |
| Entry layout (40 bytes, LE) | dev[4] type[4] id devOffset len addr entryOffset checksum version loadAddr |
| `osos` (main OS) | devOffset `0x4400` → partition `0x4600`, length `0x356F14`, checksum at partition `0x421C` |
| `aupd` (updater) | partition `0x35B800`. Its stored checksum isn't a plain byte sum (same on stock); it isn't checked at boot |

The image checksum is the 32-bit sum of all bytes of the image.

## Memory map

- Code is linked for address 0, so code pointers equal `osos` offsets. The image is loaded at `0x10000000`.
- The initialised data section is addressed in RAM as **`osos` offset + `0x10062200`**.
  Example: the opcode spec table lives at `osos+0x331C44` and is referenced as `0x10393E44`.

## Strings

UI strings are stored per language as NUL-terminated, 4-byte-aligned ASCII. The English block
starts at `osos+0x1B3400`. Code doesn't point at them directly; they're resolved through resource
records. That's why same-length in-place swaps (patch 1) are the safe way to rename things.

Each category name appears five times in the English block: the Music menu, "All …", the
main-menu settings checklist, the main-menu item list, and the shuffle/settings list. "Genres" and
"Composers" (patch 3, `--producers`) follow the same pattern on both the 4G and the 5G. Use
`patch.py --find "Text"` to list occurrences and slot sizes (the NUL padding after a string). A
shorter replacement must be NUL-terminated within that slot, and a longer one doesn't fit.

## Music library (native code)

Internal category numbers (from the keyword array built at `0x6D43C`):

| 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| playlist | genre | artist | composer | album | song | now playing |

| Function | Address |
|---|---|
| select(category, index) dispatcher | `0xC60E4` |
| select playlist / genre / artist / composer / album / song | `0xC66B8` / `0xC5FFC` / `0xC560C` / `0xC593C` / `0xC5430` / `0xC6AB8` |
| build list: genre / artist / composer / album / song | `0xE1808` / `0xE0498` / `0xE0C28` / `0xE033C` / `0xE2D40` |
| count per category (generic query `0x4A1D0`) | artist `0x7157C`, composer `0x71680` |

Library object fields: per-category selected index at `+0x1824` and up (genre `+0x1834`,
composer `+0x182C`). The "last selection" byte at `+0x18A5` holds `2 × category + (specific ? 1 : 0)`.
Selecting a composer doesn't clear the genre selection, which is why patch 2 keeps the label
filter.

## Script engine

Much of the UI logic is bytecode for a small JavaScript-style VM (SpiderMonkey-derived opcodes):

| What | Where |
|---|---|
| Interpreter main switch (128 opcodes) | `0x8FA90` |
| Opcode spec table (4 bytes per opcode: length in low nibble of byte 0, format in u16 at +2) | `0x331C44` |
| Script function offset table (619 entries, u32) | `0x1B5954` |
| Bytecode base | `0x1B6300`; every function starts with a u16 LE code length |

Useful opcodes: `0x3B` NAME (u16 BE operand), `0x35` GETPROP, `0x39` PUSHOBJ, `0x3A` CALL (argc),
`0x3C` NUMBER, `0x3E`–`0x43` 0/1/null/this/false/true, `0x58` UINT16 immediate, `0x54` push argument,
`0x06`/`0x07`/`0x08` goto/ifeq/ifne (signed 16-bit relative), `0x02` POPV, `0x05` RETURN.

**Global script functions are named `0x737 + function index`.** For example, `NAME 0x83B` is function #260.

### Native method binding

- Method descriptors: `0x1E03D4`, 376 × `{u16 property, u8 argc, u8 flags, u32 signature}`.
- Native functions: `0x1DFDF0`, 376 × u32. The call bridge is at `0x951C8`.
  Ordinary methods index the table at `*0x1E03D0` (`0x1DFE48`, i.e. +22 entries) with
  `descriptor − class.base`.
- For the music library class, the net mapping is **native index = descriptor index + 15**.
  This was validated by matching argument counts. Script property numbers:

| Property | Native | Property | Native |
|---|---|---|---|
| `0xE7` | select playlist | `0xFB` | set root category |
| `0xE8` | select artist | `0xFC` | build artist list |
| `0xE9` | select composer | `0xFD` | build composer list |
| `0xEA` | select album | `0xFE` | build album list |
| `0xEB` | select genre | `0xFF` | build genre list |
| `0xEE` | play | `0x100` | build song list |
| `0xEF` | select song | | |

### Browse handlers (script functions)

| Category | Open list | Select item → opens next |
|---|---|---|
| composer | #236 (global `0x823`) | #239 → `0x82A` (albums) |
| album | #243 (`0x82A`) | #246 → `0x81A` (songs) |
| artist | #260 (`0x83B`) | #262 → `0x82A` (albums) |
| genre | #266 (`0x841`) | **#268 → `0x83B` (artists)** |

The genre "item picked" handler (#268) is:

```
NAME 0x9AD; GETPROP 0xEB; PUSHOBJ; ARG 0; CALL 1      ; library.selectGenre(index)
NAME 0x76B; PUSHOBJ; UINT16 0x3300; UINT16 0x331E; CALL 2
NAME 0x83B; PUSHOBJ; ARG 0; CALL 1                    ; openArtists(index)
```

**Patch 2** changes the operand of the last `NAME` from `0x083B` to `0x0823` (open Composers). That's
one byte at bytecode `0x4C58` = `osos+0x1BAF58` = partition `0x1BF558`. The Music menu's own Artists
(#259) and Composers (#237) entries call the openers separately and aren't affected.

## Tooling

The analysis used [Capstone](https://www.capstone-engine.org/) (ARM mode) for disassembly, plus a
small bytecode disassembler driven by the opcode spec table. To extend the patches, the useful
moves were:
1. map native functions by tracing a known feature (e.g. the Notes `ipod:music?` link parser),
2. map script properties to natives through the descriptor table,
3. read the per-category handler blocks in the bytecode.

## iPod Video (5G) port

The 5G firmware in the user's backup uses the same image format and the same script VM (identical
opcode spec table at `osos+0x6BC140`). Offsets below are `osos` offsets (partition = `+0x4600`).

| What | 5G |
|---|---|
| `osos` length / stock checksum | `0x735A00` / `0x2C7C48F3` |
| Other images | `rsrc`, `aupd`, `hibe` (hibernation image at partition `0xD40C00`, contains data) |
| English strings | around `0x4B1000` |
| Script function table | `0x4B47D8`, 1065 × u32 (count field `0x428` just before it) |
| Bytecode base | table end + 8 = `0x4B5884` (the 8 bytes are u32 `0x10F79`, u32 `0x30000`) |
| Global name of function *i* | `0xF79 + i` |
| Library object / UI command base | name `0x13A4` / `0x6380` |

The name offset was found by scoring every candidate offset on how well call argument counts
match the callee's argument use; the same method returns `0x737` on the 4G, and `0xF79` also
appears in the 8 bytes after the table.

| Category | Open list | builds with | Item picked → opens |
|---|---|---|---|
| artist | #240 (`0x1069`) | `0x125` | #242 → `0x1054` (albums) |
| composer | #211 (`0x104C`) | `0x126` | #214 → `0x1054` (albums) |
| genre | #246 (`0x106F`) | `0x12B` | **#248 → `0x1069` (artists)** |

#240 and #211 are identical except for the list they build. The 5G composer patch changes the
operand of #248's last `NAME` from `0x1069` to `0x104C`: one byte at `osos+0x4BA8FA`
(partition `0x4BEEFA`), `69` → `4C`.
