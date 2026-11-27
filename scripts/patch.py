#!/usr/bin/env python3
"""Build a patched iPod firmware image from a backup. Never touches the device.

Supported (--model, default 4g):
  4g     iPod 4th gen click wheel (iPod Q21), firmware 3.1.1
  5g     iPod Video 5th gen, the build in the user's backup          (--5g is short for --model 5g)
  55g    iPod Video 5.5th gen: the same osos and aupd as 5g, laid out in 2048-byte sectors (160 MiB partition)
  nano   iPod nano 1st gen, the build in the user's backup (osos 0x54EF30 bytes; 64 MiB like the 5g)
  photo  iPod photo / iPod color (iPod P98), firmware 1.2.1 (4.2.1)  (--photo is short for --model photo)

Usage:
  python3 scripts/patch.py --check                      # inspect firmware/ipod_fw_backup.bin, change nothing
  python3 scripts/patch.py --labels --composers         # -> firmware/ipod_fw_patched.bin
  python3 scripts/patch.py --5g --check                 # inspect firmware/ipod5g_fw_backup.bin
  python3 scripts/patch.py --5g --labels --composers    # -> firmware/ipod5g_fw_patched.bin
  python3 scripts/patch.py --photo --check              # inspect firmware/ipodphoto_fw_backup.bin
  python3 scripts/patch.py --labels -i IN.bin -o OUT.bin
  python3 scripts/patch.py --photo --labels --plan --json  # what would change, as JSON; writes nothing
  python3 scripts/patch.py --photo --exact --labels     # labels on, every other patch removed
  python3 scripts/patch.py --photo --exact              # remove all patches (back to the original bytes)

  python3 scripts/patch.py --find "Composers"           # read-only string search (for new renames)

Patches:
  --labels     rename the English "Genres" menu labels to "Labels" (5 strings)
  --composers  after picking a genre/label, show Composers instead of Artists (1 byte)
  --producers  rename the English "Composers" menu labels to "Producers" (5 strings)
  --volume     remove the built-in (European) volume limit (2 bytes)
  --dnd FILE   iPod photo and iPod Video: your own "Do not disconnect" picture (100x100 BMP; "keep" = keep the current one)
  --logo       iPod photo and iPod Video: the boot Apple logo upside down (in the encrypted aupd image)
  --logo-image FILE   iPod photo and iPod Video: your own boot logo (photo 78x100, Video 62x78 BMP;
                      "keep" = keep the current one, "mirror" = Apple's logo mirrored left-right)

--exact: build exactly the selection. Patches that are named are applied; patches that are not named
are put back to their original bytes (removed) if the input has them. Without --exact a build only
adds patches and leaves the others as they are in the input.

Safety: the input must be a full firmware partition of the selected model whose osos image has the
exact expected size and a valid checksum, and every patched location must contain exactly the
expected original bytes (or already the patched bytes). Otherwise the script stops without writing.
"""
import argparse, hashlib, json, os, struct, sys

ENTRY = 0x4200                  # first image-directory entry (format v3: dir_off 0x4000 + 0x200)
CHK_OFF = ENTRY + 28            # osos checksum field (partition offset 0x421C)

MODELS = {
    '4g': {
        'name': 'iPod 4G firmware 3.1.1',
        'part_size': 33554432,
        'osos_len': 0x356F14,
        'input': 'ipod_fw_backup.bin',
        'output': 'ipod_fw_patched.bin',
        'patches': {
            'labels': {
                'desc': 'English "Genres" -> "Labels" (5 menu strings)',
                'edits': [(o, b'Genres', b'Labels') for o in (0x1B7C3C, 0x1B8248, 0x1B95F2, 0x1B9788, 0x1B9B4C)],
                'context': [],
            },
            'composers': {
                'desc': 'Genre/Label list opens Composers instead of Artists (script func #268: name 0x83B -> 0x823)',
                'edits': [(0x1BF558, b'\x3b', b'\x23')],
                # bytes around the edit that must match exactly
                'context': [(0x1BF552, bytes.fromhex('3a000202' '3b08'), 0x1BF559, bytes.fromhex('39540000' '3a0001' '0243'))],
            },
            'producers': {
                'desc': 'English "Composers" -> "Producers" (5 menu strings)',
                'edits': [(o, b'Composers', b'Producers') for o in (0x1B7C44, 0x1B822C, 0x1B95E6, 0x1B977C, 0x1B9B70)],
                'context': [],
            },
            'volume': {
                # Volume-cap check at osos 0x799E8 (1 caller, which sets the max volume: capped 216, else 256):
                #   ldr r0,=0x1039DA34; ldr r0,[r0,#0x138]; and r0,r0,#1; mov pc,lr
                # 'and r0,r0,#1' (01 00 00 e2) -> 'and r0,r0,#0' (00 01 00 e2): never capped.
                'desc': 'No built-in volume limit (volume-cap check always answers "no")',
                'edits': [(0x7DFF0, b'\x01\x00', b'\x00\x01')],
                'context': [(0x7DFE8, bytes.fromhex('08009fe5' '380190e5'), 0x7DFF2, bytes.fromhex('00e2' '0ef0a0e1' '34da3910'))],
            },
        },
    },
    '5g': {
        'name': 'iPod Video 5G (osos 0x735A00 bytes)',
        'part_size': 67108864,
        'osos_len': 0x735A00,
        'input': 'ipod5g_fw_backup.bin',
        'aupd_flashed': 0x4258,         # aupd is the third directory entry (see the photo's note)
        'output': 'ipod5g_fw_patched.bin',
        'patches': {
            'labels': {
                'desc': 'English "Genres" -> "Labels" (5 menu strings)',
                'edits': [(o, b'Genres', b'Labels') for o in (0x4B5A04, 0x4B6760, 0x4B7FB6, 0x4B8158, 0x4B8818)],
                'context': [],
            },
            'composers': {
                'desc': 'Genre/Label list opens Composers instead of Artists (script func #248: name 0x1069 -> 0x104C)',
                'edits': [(0x4BEEFA, b'\x69', b'\x4c')],
                'context': [(0x4BEEF4, bytes.fromhex('3a000202' '3b10'), 0x4BEEFB, bytes.fromhex('39540000' '3a0001' '0243'))],
            },
            'producers': {
                'desc': 'English "Composers" -> "Producers" (5 menu strings)',
                'edits': [(o, b'Composers', b'Producers') for o in (0x4B5A0C, 0x4B6744, 0x4B7FA6, 0x4B814C, 0x4B884C)],
                'context': [],
            },
            'logo': {
                # The 62x78 RGB565 boot logo (iPodWizard index 417) in the aupd image, which is RC4-encrypted
                # with a key hidden in its security block (aupd_rc4_key). The pixels follow a 28-byte 'LoGo'
                # header (until 2026-11-27 patch.py read them 4 bytes early, which shifted pictures 2 pixels). The aupd checksum (directory field 0x426C) is the byte sum of the decrypted aupd.
                'desc': 'Boot Apple logo (62x78, in aupd): upside down, or your own BMP',
                'cipher': {'image': 'aupd', 'offset': 0xCF9E08, 'height': 78, 'width': 62, 'row_bytes': 124,
                           'rc4': True,
                           # 'LoGo' tag (byte-reversed), 0, height 78, width 62, row bytes 124, 52, 0, length 9672, 0
                           'header': bytes.fromhex('6f476f4c00000000' '4e003e00' '7c003400' '00000000' 'c8250000' '00000000'),
                           'stock_sha256': 'bc6955e6d2ac92827ef2c89c1dcc7e308a0dfce0eb2abef7cecc05b438e1dfb7',
                           # originals/5g-logo.bin saved with the old, 4-byte-early layout: still accepted
                           'legacy_stock_sha256': '2ed2994e187f559927c6c33d8a6b8bb919e3e1517b5ff22de89899f7b1fda6e7',
                           # iPodWizard's flip (a 24-bit colour round trip shifts some pixels by 1 step): counts as
                           # 'applied'; XOR with this delta (pixel offset 0x58 onward) gives Apple's logo back
                           'wizard_flip': {'sha256': 'a3c19a0de2f70aad69ef3912b2c64832b5fdddfdb18d6f5ad6417db25cd464eb',
                                           'delta': '5g_logo.xor', 'delta_offset': 0x54, 'delta_length': 9552,
                                           'delta_sha256': 'c1921e6edd619643d1cb900b1f248b0d036a0af7832b716f9c743b23a07a83f3'},
                           'checksum': 0x426C},
                'context': [],
            },
            'volume': {
                # The getter behind the built-in (European) volume cap, osos 0xA0348, 2 callers:
                #   ldr r0,=0x108710DC; ldr r0,[r0,#0x94]; and r0,r0,#1; bx lr
                # 'and r0,r0,#1' (01 00 00 e2) -> 'and r0,r0,#0' (00 01 00 e2, 0 rotated): never capped.
                'desc': 'No built-in volume limit (volume-cap check always answers "no")',
                'edits': [(0xA4950, b'\x01\x00', b'\x00\x01')],
                'context': [(0xA4948, bytes.fromhex('08009fe5' '940090e5'), 0xA4952, bytes.fromhex('00e2' '1eff2fe1' 'dc108710'))],
            },
            'dnd': {
                # The "Do not disconnect" picture (iPodWizard index 372, ID 25561): 100x100 RGB565 in osos, with
                # the 5G's 28-byte picture header. Apple's pixels are identical to the iPod photo's.
                'desc': '"Do not disconnect" picture (100x100) replaced by your own BMP',
                'picture': {'header': 0x496918, 'layout': '5g', 'height': 100, 'width': 100, 'row_bytes': 200, 'bpp': 16,
                            'original_sha256': 'd988199fbbff1f087b1285f970ea577ce7feb082164e00725cae1b356cd844e3'},
                'context': [],
            },
        },
    },
    'photo': {
        'name': 'iPod photo / color firmware 1.2.1 (build 4.2.1)',
        'part_size': 33554432,
        'osos_len': 0x523514,
        # sha256 of the osos image in Apple's iPod_5.1.2.1 / iPod_11.1.2.1 updater (Firmware-11.4.2.1);
        # informational: the checks below are what decide.
        'stock_osos_sha256': '9321189b846a7317f4f575075696056e9a18c79644886a00055a402259c6fadc',
        'input': 'ipodphoto_fw_backup.bin',
        # aupd directory entry, u32 at +8: Apple's updater files ship 0; the iPod sets it to 1 once it has
        # flashed aupd into the boot ROM. A changed aupd only reaches the boot ROM (the boot logo) when
        # this is 0 again, so a build that changes aupd (or --reflash) resets it.
        'aupd_flashed': 0x4230,
        'output': 'ipodphoto_fw_patched.bin',
        'patches': {
            'labels': {
                'desc': 'English "Genres" -> "Labels" (5 menu strings)',
                'edits': [(o, b'Genres', b'Labels') for o in (0x27176C, 0x271D88, 0x2735E2, 0x2737C4, 0x273DA0)],
                'context': [],
            },
            'composers': {
                'desc': 'Genre/Label list opens Composers instead of Artists (script func #281: name 0x9EC -> 0x9D1)',
                'edits': [(0x27A088, b'\xec', b'\xd1')],
                # the whole genre "item picked" handler: selectGenre (prop 0xF0), UI command 0x331B, open list
                'context': [(0x27A06A, bytes.fromhex('3b0bb13500f0395600003a000102' '3b090d3958330058331b3a000202' '3b09'),
                             0x27A089, bytes.fromhex('39540000' '3a0001' '0243'))],
            },
            'producers': {
                'desc': 'English "Composers" -> "Producers" (5 menu strings)',
                'edits': [(o, b'Composers', b'Producers') for o in (0x271774, 0x271D6C, 0x2735D2, 0x2737B8, 0x273DD4)],
                'context': [],
            },
            'volume': {
                # Volume-cap check at osos 0x83278 (1 caller, which sets the max volume: capped 216, else 256):
                #   ldr r0,=0x1053C3B4; ldr r0,[r0,#0x138]; and r0,r0,#1; mov pc,lr
                # 'and r0,r0,#1' (01 00 00 e2) -> 'and r0,r0,#0' (00 01 00 e2): never capped.
                'desc': 'No built-in volume limit (volume-cap check always answers "no")',
                'edits': [(0x87880, b'\x01\x00', b'\x00\x01')],
                'context': [(0x87878, bytes.fromhex('08009fe5' '380190e5'), 0x87882, bytes.fromhex('00e2' '0ef0a0e1' 'b4c35310'))],
            },
            'dnd': {
                # The "Do not disconnect" picture (iPodWizard index 97, ID 13115): 100x100 RGB565 in osos,
                # replaced by the user's own BMP. Any content counts as 'applied'; 'original' is Apple's.
                'desc': '"Do not disconnect" picture (100x100) replaced by your own BMP',
                'picture': {'header': 0x247A08, 'height': 100, 'width': 100, 'row_bytes': 200, 'bpp': 16,
                            'original_sha256': 'd988199fbbff1f087b1285f970ea577ce7feb082164e00725cae1b356cd844e3'},
                'context': [],
            },
            'logo': {
                # The 78x100 RGB565 boot logo (iPodWizard index 179) lives in the encrypted aupd image. The
                # encryption is a position-based XOR stream; the key for the logo's 15,600 bytes was
                # recovered from three dumps (stock, iPodWizard-flipped, iPodWizard custom picture with
                # its BMP), and checked against all three. The aupd checksum (directory field 0x4244) is
                # the byte sum of the decrypted aupd, so it moves by the change in the pixel byte sum.
                'desc': 'Boot Apple logo (78x100, in aupd): upside down, or your own BMP',
                'cipher': {'image': 'aupd', 'offset': 0x5DDAB4, 'height': 100, 'width': 78, 'row_bytes': 156,
                           'key': 'photo_logo.key',
                           'key_sha256': '1fa3e45fb36e0f2e7b1c34b2d4997592912bcacc46623f5251c68e4e4f7111da',
                           'stock_sha256': '5153e22e0eb08008e9523a188aa1c57b70f0693c175e7caef4afe7dd19eb65c4',
                           # the rest of aupd (logo bytes zeroed) must be exactly this, or the key doesn't apply
                           'rest_sha256': '6e16120827071e7746286bd2794affeb955188ce973abe843a1b434881f5652b',
                           'checksum': 0x4244},
                'context': [],
            },
        },
    },
}

def _shifted(base, name, part_size, osos_len, files, osos_delta, aupd_delta):
    """A model whose osos and aupd hold exactly the same bytes as `base`'s, at other partition offsets
    (the image directory itself, with the checksum fields and the aupd flag, stays at 0x4200)."""
    import copy
    m = copy.deepcopy(base)
    m.update({'name': name, 'part_size': part_size, 'osos_len': osos_len, 'input': files[0], 'output': files[1]})
    for p in m['patches'].values():
        if 'edits' in p:
            p['edits'] = [(o + osos_delta, old, new) for o, old, new in p['edits']]
        p['context'] = [(a + osos_delta, pre, b + osos_delta, post) for a, pre, b, post in p.get('context', [])]
        if 'picture' in p:
            p['picture']['header'] += osos_delta
        if 'cipher' in p:
            x = p['cipher']
            x['offset'] += aupd_delta
            for k in ('wizard_flip', 'legacy_stock_sha256'):   # those exist only for the 5G user's own dumps
                x.pop(k, None)
    return m

# iPod Video 5.5G: the 160 MiB partition uses 2048-byte sectors, so every image starts one 2048-byte
# sector after its directory offset (0x200 on the others); osos (0x5000, not 0x4600) and aupd
# (0xC3C800, not 0xC3A400) hold byte-identical contents to the 5G's 1.3 build (checked on a 5.5G
# dump: osos identical to 5G stock, aupd decrypts to the 5G's plaintext with the same checksum).
MODELS['55g'] = _shifted(MODELS['5g'], 'iPod Video 5.5G (osos 0x735A00 bytes, 2048-byte sectors)',
                         167772160, 0x736000, ('ipod55g_fw_backup.bin', 'ipod55g_fw_patched.bin'),
                         0x5000 - 0x4600, 0xC3C800 - 0xC3A400)
MODELS['55g']['sector'] = 0x800

# iPod nano 1st gen (USB product 0x120A): same image format, script VM and aupd encryption as the 5G,
# its own osos build (0x54EF30 bytes, version 0xC009). Partition offsets (osos at 0x4600):
# - English strings: "Genres" and "Composers" five times each, in the same contexts as on the 5G.
# - Script function table at osos 0x32089C (809 entries, trailer u32 0x10E93, u32 0x30000 at 0x321540),
#   names 0xE93 + i. Genre "item picked" handler #244 (0xF87: select prop 0x104, UI cmd 0x63A7) ends
#   with openArtists 0xF7F (#236: builds 0x117, descriptor #237 setRoot(1)); openComposers is 0xF62
#   (#207: builds 0x118, descriptor #209 setRoot(2)). Composers patch: that NAME operand 7F -> 62.
# - Volume cap getter at osos 0x24C28, identical to the 5G's (object 0x10731DAC, field 0x94, bit 0),
#   2 callers; one does the 256/216 maximum-volume choice at osos 0x317D4.
# - Boot logo: aupd (RC4, key from its security block) holds the 5G's 'LoGo' picture with the same
#   pixels; pixels at partition 0x1593724. The "Do not disconnect" picture isn't identified (the nano's
#   own 100x100 picture is a check mark, its pictures use format 0x2565), so --dnd is not offered.
MODELS['nano'] = {
    'name': 'iPod nano 1st gen (osos 0x54EF30 bytes)',
    'part_size': 67108864,
    'osos_len': 0x54EF30,
    'input': 'ipodnano_fw_backup.bin',
    'output': 'ipodnano_fw_patched.bin',
    'aupd_flashed': 0x4258,
    'patches': {
        'labels': {
            'desc': 'English "Genres" -> "Labels" (5 menu strings)',
            'edits': [(o, b'Genres', b'Labels') for o in (0x3209D4, 0x3219A8, 0x324406, 0x3245C8, 0x324A34)],
            'context': [],
        },
        'composers': {
            'desc': 'Genre/Label list opens Composers instead of Artists (script func #244: name 0xF7F -> 0xF62)',
            'edits': [(0x32A7B8, b'\x7f', b'\x62')],
            'context': [(0x32A7B2, bytes.fromhex('3a000202' '3b0f'), 0x32A7B9, bytes.fromhex('39540000' '3a0001' '0243'))],
        },
        'producers': {
            'desc': 'English "Composers" -> "Producers" (5 menu strings)',
            'edits': [(o, b'Composers', b'Producers') for o in (0x3209DC, 0x32198C, 0x3243F6, 0x3245BC, 0x324A68)],
            'context': [],
        },
        'logo': {
            'desc': 'Boot Apple logo (62x78, in aupd): upside down, or your own BMP',
            'cipher': dict(MODELS['5g']['patches']['logo']['cipher'], offset=0x1593724),
            'context': [],
        },
        'volume': {
            'desc': 'No built-in volume limit (volume-cap check always answers "no")',
            'edits': [(0x29230, b'\x01\x00', b'\x00\x01')],
            'context': [(0x29228, bytes.fromhex('08009fe5' '940090e5'), 0x29232, bytes.fromhex('00e2' '1eff2fe1' 'ac1d7310'))],
        },
    },
}
for k in ('wizard_flip', 'legacy_stock_sha256'):        # those exist only for the 5G user's own dumps
    MODELS['nano']['patches']['logo']['cipher'].pop(k, None)

def sector(buf):
    """Sector size of a firmware partition: 2048 bytes for the 5.5G's 160 MiB partition, else 512."""
    return next((m.get('sector', 0x200) for m in MODELS.values() if m['part_size'] == len(buf) and 'sector' in m), 0x200)

JSON = False


def flip_rows(d, row_bytes, height):
    return b''.join(d[r * row_bytes:(r + 1) * row_bytes] for r in reversed(range(height)))

def mirror_rows(d, row_bytes, height, width):
    """Left-right mirror of 16-bit pixels (any row padding stays at the end of the row)."""
    out = bytearray(d)
    for r in range(height):
        o = r * row_bytes
        for c in range(width):
            out[o + 2 * c:o + 2 * c + 2] = d[o + 2 * (width - 1 - c):o + 2 * (width - c)]
    return bytes(out)

def patchdata(name, size, sha):
    try:
        d = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'patchdata', name), 'rb').read()
    except OSError:
        d = b''
    if len(d) != size or hashlib.sha256(d).hexdigest() != sha:
        fail(f'scripts/patchdata/{name} is missing or damaged')
    return d

def aupd_rc4_key(sec):
    """The 4-byte RC4 key hidden in an image's security block (the sector before its data: 512 bytes, or
    2048 on the 5.5G, where the sum runs over the whole 2048 bytes), or None when no marker is enabled.
    BadBlox's method (ipodlinux.org wiki "Flash Decryption")."""
    M = 0xFFFFFFFF
    offs = (0x5, 0x25, 0x6F, 0x69, 0x15, 0x4D, 0x40, 0x34)
    word = lambda p: struct.unpack_from('<I', sec, p)[0]
    def enabled(m):
        d = m ^ (m & 0xFF) * 0x01010101
        a, b, c = d >> 24, d >> 16 & 0xFF, d >> 8 & 0xFF
        return a != 0 and a < b < c and (a & 0xF) > (b & 0xF) > (c & 0xF) != 0
    for i in range(7):
        m = word(offs[i] * 4)
        if not enabled(m):
            continue
        key = m ^ word(offs[i + 1] * 4 + 8) ^ 0x54C3A298
        r1 = 0x6F
        for n in range(2, len(sec) // 4, 2):
            a, b = word(n * 4), word(n * 4 + 4)
            r1 = ((r1 ^ (a | b >> 16)) + ((a & 0xFFFF) | b)) & M
        return struct.pack('<I', key ^ r1)
    return None

def rc4(key, n):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 255
        s[i], s[j] = s[j], s[i]
    out = bytearray(n)
    i = j = 0
    for k in range(n):
        i = (i + 1) & 255
        j = (j + s[i]) & 255
        s[i], s[j] = s[j], s[i]
        out[k] = s[(s[i] + s[j]) & 255]
    return bytes(out)

_rc4_cache = {}

def cipher_key(buf, x):
    """The keystream over a 'cipher' patch's pixels, or None when it can't be derived from this input."""
    n = x['height'] * x['row_bytes']
    if not x.get('rc4'):
        return patchdata(x['key'], n, x['key_sha256'])
    ks = image_stream(buf, x)
    rel = x['offset'] - {i['type']: i for i in images(buf)}[x['image']]['offset']
    return None if ks is None else ks[rel:rel + n]

def image_stream(buf, x):
    """RC4 keystream over the whole image a 'cipher' patch lives in (key from its security block)."""
    img = {i['type']: i for i in images(buf)}.get(x['image'])
    if not img:
        return None
    sec = bytes(buf[img['offset'] - sector(buf):img['offset']])     # the sector before the data
    key = aupd_rc4_key(sec)
    if key is None:
        return None
    if (key, img['length']) not in _rc4_cache:
        _rc4_cache[key, img['length']] = rc4(key, img['length'])
    return _rc4_cache[key, img['length']]

def cipher_plain(buf, x):
    """The decrypted picture of a 'cipher' patch, or None when the image around it isn't the expected one."""
    img = {i['type']: i for i in images(buf)}.get(x['image'])
    n = x['height'] * x['row_bytes']
    o = x['offset']
    if not img or not (img['offset'] <= o and o + n <= img['offset'] + img['length']):
        return None
    if not x.get('rc4'):
        rest = bytearray(buf[img['offset']:img['offset'] + img['length']])
        rest[o - img['offset']:o - img['offset'] + n] = bytes(n)
        if hashlib.sha256(rest).hexdigest() != x['rest_sha256']:
            return None
        return bytes(c ^ k for c, k in zip(buf[o:o + n], cipher_key(buf, x)))
    # RC4: the key is right and aupd intact when the picture header decrypts as expected and the
    # decrypted image's byte sum equals the checksum in the directory
    ks = image_stream(buf, x)
    if ks is None:
        return None
    rel = o - img['offset']
    data = buf[img['offset']:img['offset'] + img['length']]
    h = x['header']
    if bytes(c ^ k for c, k in zip(data[rel - len(h):rel], ks[rel - len(h):rel])) != h:
        return None
    total = sum(c ^ k for c, k in zip(data, ks)) & 0xFFFFFFFF
    if total != struct.unpack_from('<I', buf, x['checksum'])[0]:
        return None
    return bytes(c ^ k for c, k in zip(data[rel:rel + n], ks[rel:rel + n]))

def wizard_unflip(plain, x):
    """Apple's picture from iPodWizard's flipped one (exact), or None when it isn't that one."""
    w = x.get('wizard_flip')
    if not w or hashlib.sha256(plain).hexdigest() != w['sha256']:
        return None
    d = patchdata(w['delta'], w['delta_length'], w['delta_sha256'])
    out = bytearray(plain)
    for i, v in enumerate(d):
        out[w['delta_offset'] + i] ^= v
    return bytes(out)

def cipher_state(buf, x):
    plain = cipher_plain(buf, x)
    if plain is None:
        return 'mismatch'
    if hashlib.sha256(plain).hexdigest() == x['stock_sha256']:
        return 'original'
    if hashlib.sha256(flip_rows(plain, x['row_bytes'], x['height'])).hexdigest() == x['stock_sha256'] \
            or wizard_unflip(plain, x) is not None:
        return 'applied'
    return 'custom'

def read_bmp(path, width, height):
    """A BMP file as RGB565 little-endian pixels, top row first (the iPod's format). Accepts 16-bit
    (RGB565 bitfields or RGB555), 24-bit and 32-bit uncompressed BMPs of exactly width x height."""
    try:
        b = open(path, 'rb').read()
    except OSError as e:
        fail(f'cannot read {path}: {e.strerror}')
    if b[:2] != b'BM' or len(b) < 54:
        fail(f'{os.path.basename(path)} is not a BMP file')
    off = struct.unpack_from('<I', b, 10)[0]
    w, h = struct.unpack_from('<ii', b, 18)
    bpp, comp = struct.unpack_from('<HI', b, 28)
    if (w, abs(h)) != (width, height):
        fail(f'{os.path.basename(path)} is {w}x{abs(h)}; it must be exactly {width}x{height}')
    masks = struct.unpack_from('<III', b, 54) if comp == 3 and len(b) >= 66 else None
    if not ((bpp in (24, 32) and comp in (0, 3)) or (bpp == 16 and comp in (0, 3))):
        fail(f'{os.path.basename(path)}: {bpp}-bit BMP (compression {comp}) is not supported; save it as 16- or 24-bit')
    rb = (w * bpp + 31) // 32 * 4
    if off + rb * abs(h) > len(b):
        fail(f'{os.path.basename(path)} is truncated')
    out = bytearray()
    rows = range(abs(h) - 1, -1, -1) if h > 0 else range(abs(h))     # positive height = bottom-up
    for r in rows:
        row = b[off + r * rb:off + r * rb + rb]
        for x in range(w):
            if bpp == 16:
                v = row[2 * x] | row[2 * x + 1] << 8
                if masks == (0xF800, 0x07E0, 0x001F):
                    px = v
                elif comp == 0 or masks == (0x7C00, 0x03E0, 0x001F):     # RGB555
                    px = (v & 0x7C00) << 1 | (v & 0x03E0) << 1 | (v & 0x03E0) >> 4 & 0x20 | v & 0x1F
                else:
                    fail(f'{os.path.basename(path)}: unsupported 16-bit colour masks')
            else:
                bb, gg, rr = row[x * (bpp // 8):x * (bpp // 8) + 3]
                px = (rr * 31 // 255) << 11 | (gg * 63 // 255) << 5 | bb * 31 // 255     # as iPodWizard does
            out += struct.pack('<H', px)
    return bytes(out)

def write_bmp(path, px, width, height, row_bytes):
    """Save RGB565 LE pixels (top row first) as a 24-bit BMP, atomically (for the app's preview)."""
    rb = (width * 3 + 3) // 4 * 4
    rows = []
    for r in range(height):
        row = bytearray()
        for x in range(width):
            v = px[r * row_bytes + 2 * x] | px[r * row_bytes + 2 * x + 1] << 8
            row += bytes(((v & 0x1F) * 255 // 31, (v >> 5 & 0x3F) * 255 // 63, (v >> 11) * 255 // 31))
        rows.append(bytes(row) + bytes(rb - len(row)))
    data = b''.join(reversed(rows))                     # BMP rows are bottom-up
    hdr = b'BM' + struct.pack('<IHHI', 54 + len(data), 0, 0, 54) + \
        struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, len(data), 2835, 2835, 0, 0)
    with open(path + '.tmp', 'wb') as f:
        f.write(hdr + data)
    os.replace(path + '.tmp', path)

def result_picture(buf, p):
    """(pixels, width, height, row_bytes) of a picture patch as it is in buf, or None."""
    if 'picture' in p:
        r = picture_region(buf, p)
        f = p['picture']
        return None if r is None else (bytes(buf[r[0]:r[0] + r[1]]), f['width'], f['height'], f['row_bytes'])
    if 'cipher' in p:
        x = p['cipher']
        px = cipher_plain(buf, x)
        return None if px is None else (px, x['width'], x['height'], x['row_bytes'])
    return None

def picture_region(buf, p):
    """(offset, length) of a 'picture' patch's pixels, or None when the header isn't the expected one."""
    f = p['picture']
    n = f['height'] * f['row_bytes']
    if f.get('layout') == '5g':     # u32 format (0x565 = RGB565), u16 row bytes, u16 bpp, 0, 0, height, width, length
        hdr = struct.pack('<IHHIIIII', 0x565, f['row_bytes'], f['bpp'], 0, 0, f['height'], f['width'], n)
    else:                           # 4G / photo: height, width, u16 row bytes, u16 bpp, 0, length
        hdr = struct.pack('<IIHHII', f['height'], f['width'], f['row_bytes'], f['bpp'], 0, n)
    o = f['header']
    if bytes(buf[o:o + len(hdr)]) != hdr:
        return None
    return o + len(hdr), n

def fail(msg):
    if JSON:
        print(json.dumps({'ok': False, 'error': msg}))
        sys.exit(1)
    sys.exit(f'ERROR: {msg}\nNothing was written.')

def say(*a):
    if not JSON:
        print(*a)

def osos_info(buf, m):
    if len(buf) != m['part_size']:
        other = [k for k, v in MODELS.items() if v['part_size'] == len(buf)]
        hint = f' (that is the size of a {"/".join(other)} dump: use --model {other[0]})' if other else ''
        fail(f'input is {len(buf)} bytes, expected {m["part_size"]} for {m["name"]}{hint}')
    if buf[0x100:0x104] != b']ih[':
        fail('no "]ih[" firmware header at 0x100; this is not an iPod firmware partition')
    dir_off, _, ver = struct.unpack_from('<IHH', buf, 0x104)
    if (dir_off, ver) != (0x4000, 3) or buf[ENTRY + 4:ENTRY + 8] != b'soso':
        fail(f'unexpected image directory (dir_off=0x{dir_off:x}, version={ver})')
    devoff, length = struct.unpack_from('<II', buf, ENTRY + 12)
    start = devoff + sector(buf)
    if length != m['osos_len']:
        other = [k for k, v in MODELS.items() if v['osos_len'] == length]
        hint = f' (it matches --model {other[0]})' if other else ''
        fail(f'osos length is 0x{length:x}, expected 0x{m["osos_len"]:x}; this is not {m["name"]}{hint}')
    stored = struct.unpack_from('<I', buf, CHK_OFF)[0]
    calc = sum(buf[start:start + length]) & 0xFFFFFFFF
    if stored != calc:
        fail(f'osos checksum invalid (stored 0x{stored:08x}, calculated 0x{calc:08x}); corrupt dump?')
    return start, length, stored

def images(buf):
    """The firmware partition's image directory: [{type, offset (partition), length}]."""
    out = []
    for i in range(16):
        e = ENTRY + 40 * i
        typ = buf[e + 4:e + 8][::-1]
        if not typ.strip(b'\0') or not all(32 < c < 127 for c in typ):
            break
        devoff, length = struct.unpack_from('<II', buf, e + 12)
        out.append({'type': typ.decode(), 'offset': devoff + sector(buf), 'length': length})
    return out

def state(buf, p):
    """'original', 'applied' or 'mismatch' for one patch."""
    if 'cipher' in p:        # decrypted: Apple's, Apple's flipped, or another picture ('custom')
        return cipher_state(buf, p['cipher'])
    if 'picture' in p:       # any content is 'applied' (a custom picture); Apple's pixels are 'original'
        r = picture_region(buf, p)
        if r is None:
            return 'mismatch'
        o, n = r
        return 'original' if hashlib.sha256(bytes(buf[o:o + n])).hexdigest() == p['picture']['original_sha256'] else 'applied'
    if p['edits'] is None:
        return 'mismatch'
    for a, pre, b, post in p['context']:
        if buf[a:a + len(pre)] != pre or buf[b:b + len(post)] != post:
            return 'mismatch'
    olds = all(buf[o:o + len(old)] == old for o, old, new in p['edits'])
    news = all(buf[o:o + len(new)] == new for o, old, new in p['edits'])
    return 'original' if olds else 'applied' if news else 'mismatch'

def find(buf, start, length, text):
    """Read-only string search (ASCII, plus UTF-16LE/BE) inside osos, with context and NUL-padded slot size."""
    hits = 0
    for enc in ('ascii', 'utf-16-le', 'utf-16-be'):
        try:
            needle = text.encode(enc)
        except UnicodeEncodeError:
            continue
        p = buf.find(needle, start, start + length)
        while p != -1:
            hits += 1
            # room available for a replacement: up to the next non-NUL byte after the terminator
            end = p + len(needle)
            while end < start + length and buf[end] == 0:
                end += 1
            ctx = ''.join(chr(c) if 32 <= c < 127 else '·' for c in buf[max(start, p - 24):p + len(needle) + 24])
            print(f'0x{p:07x} [{enc}] slot {end - p - 1:3d} bytes | {ctx}')
            p = buf.find(needle, p + 1, start + length)
    print(f'{hits} match(es) for {text!r} (offsets are partition offsets; nothing was changed)')

def main():
    global JSON
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--model', choices=sorted(MODELS), help='firmware model (default 4g)')
    ap.add_argument('--5g', dest='g5', action='store_true', help='short for --model 5g')
    ap.add_argument('--55g', dest='g55', action='store_true', help='short for --model 55g')
    ap.add_argument('--nano', action='store_true', help='short for --model nano')
    ap.add_argument('--photo', action='store_true', help='short for --model photo')
    ap.add_argument('-i', '--input')
    ap.add_argument('-o', '--output')
    ap.add_argument('--labels', action='store_true', help='English "Genres" -> "Labels"')
    ap.add_argument('--composers', action='store_true', help='Genre/Label list opens Composers instead of Artists')
    ap.add_argument('--producers', action='store_true', help='English "Composers" -> "Producers"')
    ap.add_argument('--volume', action='store_true', help='remove the built-in (European) volume limit')
    ap.add_argument('--dnd', metavar='FILE.bmp',
                    help='iPod photo and iPod Video: your own "Do not disconnect" picture (100x100 BMP); "keep" keeps the one on the iPod')
    ap.add_argument('--originals', metavar='DIR',
                    help='where Apple\'s original pictures are saved before a custom one replaces them '
                         '(default: an "originals" folder next to the input)')
    ap.add_argument('--logo-image', metavar='FILE.bmp',
                    help='iPod photo (78x100) and iPod Video (62x78): your own boot logo BMP instead of the flipped one; "keep" keeps the one on the iPod, "mirror" mirrors Apple\'s logo left-right')
    ap.add_argument('--logo', action='store_true', help='iPod photo and iPod Video: boot Apple logo upside down')
    ap.add_argument('--reflash', action='store_true',
                    help='iPod photo and iPod Video: mark aupd as not yet flashed, so the iPod copies it into its boot ROM at the next start')
    ap.add_argument('--exact', action='store_true',
                    help='unnamed patches are removed (original bytes restored); with no patch named: remove all')
    ap.add_argument('--check', action='store_true', help='only inspect the input and report')
    ap.add_argument('--plan', action='store_true', help='show exactly what would change, but write nothing')
    ap.add_argument('--json', action='store_true', help='machine-readable output (for the Clickwheel app)')
    ap.add_argument('--preview', metavar='DIR',
                    help='also save the pictures of the result (boot logo, DnD) as BMPs in DIR (for the app)')
    ap.add_argument('--find', metavar='TEXT', help='read-only: list every occurrence of TEXT in the osos image')
    a = ap.parse_args()
    JSON = a.json
    picked = [k for k, on in (('5g', a.g5), ('55g', a.g55), ('nano', a.nano), ('photo', a.photo)) if on] + ([a.model] if a.model else [])
    if len(set(picked)) > 1:
        fail(f'conflicting models: {", ".join(sorted(set(picked)))}')
    model = picked[0] if picked else '4g'
    m = MODELS[model]
    patches = m['patches']
    a.input = a.input or os.path.join(root, 'firmware', m['input'])
    a.output = a.output or os.path.join(root, 'firmware', m['output'])

    if not os.path.exists(a.input):
        fail(f'{a.input} not found (make the backup first)')
    orig = open(a.input, 'rb').read()
    start, length, chk = osos_info(orig, m)
    patches = {n: dict(p, edits=[]) if 'picture' in p or 'cipher' in p else p for n, p in patches.items()}
    if a.logo_image and not ('logo' in patches and 'cipher' in patches['logo']):
        fail(f'--logo-image is not available for {m["name"]}')
    if a.logo_image and a.logo:
        fail('choose --logo (flip) or --logo-image (your own picture), not both')
    for n in ('labels', 'composers', 'producers', 'logo', 'dnd', 'volume'):
        if getattr(a, n) and n not in patches:
            fail(f'--{n} is not available for {m["name"]}')
    if a.find:
        find(orig, start, length, a.find)
        return
    sha_in = hashlib.sha256(orig).hexdigest()
    stock = m.get('stock_osos_sha256')
    osos_stock = (hashlib.sha256(orig[start:start + length]).hexdigest() == stock) if stock else None
    say(f'model : {m["name"]}')
    say(f'input : {a.input}')
    say(f'sha256: {sha_in}')
    say(f'osos  : 0x{length:x} bytes, checksum 0x{chk:08x} (valid)')
    if osos_stock is not None:
        say(f'osos  : {"identical to" if osos_stock else "differs from"} Apple\'s stock image for this build')
    flag = m.get('aupd_flashed')
    if flag:
        say(f'aupd  : {"in the boot ROM (flag 1)" if orig[flag] == 1 else "waiting to be flashed at the next start (flag 0)"}')
    states = {n: state(orig, p) for n, p in patches.items()}
    for n, s in states.items():
        say(f'patch {n:10s}: {s}')
    report = {'ok': True, 'model': model, 'name': m['name'], 'input': a.input, 'sha256': sha_in,
              'osos': {'offset': start, 'length': length, 'checksum': chk, 'stock': osos_stock},
              'checksum_offset': CHK_OFF, 'part_size': len(orig), 'images': images(orig),
              'patches': {n: {'state': states[n], 'desc': p['desc'],
                              'edits': [{'offset': o, 'old': old.hex(), 'new': new.hex()} for o, old, new in (p['edits'] or [])]}
                          for n, p in patches.items()}}
    bad = [n for n, s in states.items() if s == 'mismatch']
    if a.check:
        report['patchable'] = not bad
        if JSON:
            print(json.dumps(report))
            sys.exit(1 if bad else 0)
        if bad:
            sys.exit(f'\nNot patchable: {", ".join(bad)} location(s) contain unexpected bytes.')
        print('\nOK: patchable.')
        return

    wanted = [n for n in patches if getattr(a, n) or (n == 'logo' and a.logo_image)]
    removed = [n for n in patches if a.exact and n not in wanted and states[n] != 'original']
    if not wanted and not a.exact and not a.reflash:
        fail('choose at least one patch: --labels, --composers, --producers (or --exact, --check / --find)')
    for n in wanted + removed:
        if states[n] == 'mismatch':
            fail(f'patch "{n}": the firmware does not contain the expected bytes')
    originals = a.originals or os.path.join(os.path.dirname(os.path.abspath(a.input)), 'originals')
    save_originals = []
    for n in wanted + removed:
        p = patches[n]
        if 'picture' not in p:
            continue
        o, size = picture_region(orig, p)
        cur = bytes(orig[o:o + size])
        keep = os.path.join(originals, f'{model}-{n}.bin')
        if n in wanted:
            arg = getattr(a, n)
            if arg == 'keep':
                if states[n] != 'applied':
                    fail(f'--{n} keep: the iPod has no custom picture to keep')
                new_px = cur
            else:
                f = p['picture']
                new_px = read_bmp(arg, f['width'], f['height'])
                if hashlib.sha256(new_px).hexdigest() == f['original_sha256']:
                    fail(f'{os.path.basename(arg)} is Apple\'s original picture; switch the change off instead')
            if states[n] == 'original':
                save_originals.append((keep, cur))
            p['edits'] = [(o, cur, new_px)]
        else:
            try:
                saved = open(keep, 'rb').read()
            except OSError:
                fail(f'patch "{n}": Apple\'s original picture was not saved ({keep}); cannot put it back')
            if hashlib.sha256(saved).hexdigest() != p['picture']['original_sha256']:
                fail(f'patch "{n}": {keep} is not Apple\'s original picture')
            p['edits'] = [(o, saved, cur)]
    for n in wanted + removed:
        p = patches[n]
        if 'cipher' not in p:
            continue
        x = p['cipher']
        size = x['height'] * x['row_bytes']
        key = cipher_key(orig, x)
        cur = cipher_plain(orig, x)
        keep = os.path.join(originals, f'{model}-{n}.bin')
        if states[n] == 'original':
            stock_px = cur
        elif states[n] == 'applied':
            stock_px = wizard_unflip(cur, x) or flip_rows(cur, x['row_bytes'], x['height'])
        else:
            try:
                stock_px = open(keep, 'rb').read()
            except OSError:
                stock_px = None
            if stock_px is not None and hashlib.sha256(stock_px).hexdigest() == x.get('legacy_stock_sha256'):
                stock_px = stock_px[4:] + bytes(4)      # old layout: 4 bytes early (the last 2 pixels are black)
            if stock_px is not None and hashlib.sha256(stock_px).hexdigest() != x['stock_sha256']:
                fail(f'patch "{n}": {keep} is not Apple\'s original picture')
        if states[n] in ('original', 'applied'):
            save_originals.append((keep, stock_px))
        if n in removed or not a.logo_image:          # back to Apple's, or Apple's flipped
            if stock_px is None:
                fail(f'patch "{n}": Apple\'s original picture was not saved ({keep}); cannot put it back')
            target = stock_px if n in removed else cur if states[n] == 'applied' else \
                flip_rows(stock_px, x['row_bytes'], x['height'])     # already flipped (e.g. by iPodWizard): leave it
        elif a.logo_image == 'keep':
            if states[n] != 'custom':
                fail('--logo-image keep: the iPod has no own boot logo to keep')
            target = cur
        elif a.logo_image == 'mirror':                 # easter egg: Apple's logo mirrored left-right
            if stock_px is None:
                fail(f'patch "{n}": Apple\'s original picture was not saved ({keep}); cannot mirror it')
            target = mirror_rows(stock_px, x['row_bytes'], x['height'], x['width'])
        else:
            target = read_bmp(a.logo_image, x['width'], x['height'])
            h = hashlib.sha256(target).hexdigest()
            if h == x['stock_sha256'] or hashlib.sha256(flip_rows(target, x['row_bytes'], x['height'])).hexdigest() == x['stock_sha256']:
                fail(f'{os.path.basename(a.logo_image)} is Apple\'s logo; use --logo, or switch the change off')
        o = x['offset']
        c_old = bytes(orig[o:o + size])
        c_new = bytes(t ^ k for t, k in zip(target, key))
        f = x['checksum']
        old_chk = struct.unpack_from('<I', orig, f)[0]
        new_chk_a = (old_chk + sum(target) - sum(cur)) & 0xFFFFFFFF
        edits = [(o, c_old, c_new), (f, struct.pack('<I', old_chk), struct.pack('<I', new_chk_a))]
        # removals are applied as (offset, restored bytes, current bytes), like the other patches
        p['edits'] = [(e, new, old) for e, old, new in edits] if n in removed else edits
    if not a.plan and os.path.exists(a.output):
        fail(f'{a.output} already exists; refusing to overwrite')

    buf = bytearray(orig)
    allowed = set(range(CHK_OFF, CHK_OFF + 4))
    imgs = {i['type']: i for i in images(orig)}

    def inside(n, o, size):
        # every edit stays in osos, or in the one other image a 'cipher' patch names (aupd)
        regions = [(start, start + length)]
        spec = patches[n].get('cipher') or {}
        name = spec.get('image')
        if name:
            if name not in imgs:
                fail(f'patch "{n}": no {name} image in this firmware')
            regions.append((imgs[name]['offset'], imgs[name]['offset'] + imgs[name]['length']))
            if 'checksum' in spec:                  # that image's checksum field in the directory
                regions.append((spec['checksum'], spec['checksum'] + 4))
        if not any(a <= o and o + size <= b for a, b in regions):
            fail(f'0x{o:x} is outside the images patch "{n}" may change')

    for n in wanted:
        for o, old, new in patches[n]['edits']:
            inside(n, o, len(new))
            buf[o:o + len(new)] = new
            allowed |= set(range(o, o + len(new)))
    for n in removed:
        for o, old, new in patches[n]['edits']:
            inside(n, o, len(old))
            buf[o:o + len(old)] = old
            allowed |= set(range(o, o + len(old)))
    # A changed aupd only takes effect after the iPod flashes it into its boot ROM: reset its flag.
    flag = m.get('aupd_flashed')
    aupd_img = imgs.get('aupd')
    aupd_changed = bool(aupd_img) and buf[aupd_img['offset']:aupd_img['offset'] + aupd_img['length']] != \
        orig[aupd_img['offset']:aupd_img['offset'] + aupd_img['length']]
    if a.reflash and not flag:
        fail(f'--reflash is not available for {m["name"]}')
    if flag and (aupd_changed or a.reflash):
        if orig[flag:flag + 4] not in (b'\0\0\0\0', b'\1\0\0\0'):
            fail(f'unexpected aupd flag 0x{orig[flag:flag + 4].hex()} at 0x{flag:x}')
        buf[flag:flag + 4] = b'\0\0\0\0'
        allowed |= set(range(flag, flag + 4))
    new_chk = sum(buf[start:start + length]) & 0xFFFFFFFF
    struct.pack_into('<I', buf, CHK_OFF, new_chk)

    # Verify: same size, only the intended bytes changed, checksum consistent.
    diff = []                           # compare 64 KiB blocks first; only differing blocks byte by byte
    B = 1 << 16
    for blk in range(0, max(len(orig), len(buf)), B):
        if orig[blk:blk + B] != buf[blk:blk + B]:
            diff += [i for i in range(blk, min(blk + B, len(orig), len(buf))) if orig[i] != buf[i]]
    if len(buf) != m['part_size'] or not set(diff) <= allowed:
        fail('verification failed: unexpected bytes changed')
    if osos_info(bytes(buf), m)[2] != new_chk:
        fail('verification failed: checksum')
    result = {n: state(bytes(buf), p) for n, p in patches.items()}
    expect = {n: ('custom' if n == 'logo' and a.logo_image else 'applied') if n in wanted
              else 'original' if n in removed else states[n] for n in patches}
    if result != expect:
        fail(f'verification failed: patch states after the build are {result}, expected {expect}')
    result_stock = (hashlib.sha256(buf[start:start + length]).hexdigest() == stock) if stock else None

    previews = {}
    if a.preview:                       # what the iPod will show: the decrypted pictures of the result
        os.makedirs(a.preview, exist_ok=True)
        for n, p in patches.items():
            r = result_picture(bytes(buf), p)
            if r:
                previews[n] = os.path.join(a.preview, f'{n}.bmp')
                write_bmp(previews[n], *r)
    sha = hashlib.sha256(buf).hexdigest()
    report.update({'previews': previews,'aupd_reflash': bool(flag) and buf[flag:flag + 4] == b'\0\0\0\0' and orig[flag:flag + 4] != b'\0\0\0\0',
                   'applied': wanted, 'removed': removed, 'exact': a.exact, 'result_states': result,
                   'result_stock': result_stock, 'new_checksum': new_chk, 'plan': a.plan, 'output': None if a.plan else a.output,
                   'output_sha256': sha, 'sectors': sorted({i // 512 * 512 for i in diff}),
                   'changes': [{'offset': i, 'old': orig[i], 'new': buf[i]} for i in diff]})
    if not a.plan:
        for path, data in save_originals:       # before a custom picture replaces Apple's for the first time
            if not os.path.exists(path):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path + '.tmp', 'wb') as f:
                    f.write(data)
                os.replace(path + '.tmp', path)
        with open(a.output, 'wb') as f:
            f.write(buf)
        os.chmod(a.output, 0o444)
        with open(a.output + '.sha256', 'w') as f:
            f.write(f'{sha}  {os.path.basename(a.output)}\n')
    if JSON:
        print(json.dumps(report))
        return
    print(f'\n{"plan (nothing written)" if a.plan else "built"}: applied {", ".join(wanted) or "nothing"}'
          + (f'; removed {", ".join(removed)}' if removed else ''))
    if result_stock is not None:
        print(f'osos  : result is {"identical to" if result_stock else "different from"} Apple\'s stock image for this build')
    print(f'osos checksum 0x{chk:08x} -> 0x{new_chk:08x} (at 0x{CHK_OFF:x})')
    print(f'{len(diff)} bytes changed:')
    for i in diff[:64]:
        print(f'  0x{i:06x}: {orig[i]:02x} -> {buf[i]:02x}')
    if len(diff) > 64:
        print(f'  ... and {len(diff) - 64} more (between 0x{diff[64]:06x} and 0x{diff[-1]:06x}; --json lists them all)')
    if not a.plan:
        print(f'wrote {a.output}\nsha256 {sha}')

if __name__ == '__main__':
    main()
