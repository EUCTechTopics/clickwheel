#!/usr/bin/env python3
"""Build a patched iPod firmware image from a backup. Never touches the device.

Supported:
  4G  iPod 4th gen click wheel (iPod Q21), firmware 3.1.1   (default)
  5G  iPod Video 5th gen, the build in the user's backup     (--5g)

Usage:
  python3 scripts/patch.py --check                      # inspect firmware/ipod_fw_backup.bin, change nothing
  python3 scripts/patch.py --labels --composers         # -> firmware/ipod_fw_patched.bin
  python3 scripts/patch.py --5g --check                 # inspect firmware/ipod5g_fw_backup.bin
  python3 scripts/patch.py --5g --labels --composers    # -> firmware/ipod5g_fw_patched.bin
  python3 scripts/patch.py --labels -i IN.bin -o OUT.bin

  python3 scripts/patch.py --find "Composers"           # read-only string search (for new renames)

Patches:
  --labels     rename the English "Genres" menu labels to "Labels" (5 strings)
  --composers  after picking a genre/label, show Composers instead of Artists (1 byte)
  --producers  rename the English "Composers" menu labels to "Producers" (5 strings)

Safety: the input must be a full firmware partition of the selected model whose osos image has the
exact expected size and a valid checksum, and every patched location must contain exactly the
expected original bytes (or already the patched bytes). Otherwise the script stops without writing.
"""
import argparse, hashlib, os, struct, sys

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
        },
    },
    '5g': {
        'name': 'iPod Video 5G (osos 0x735A00 bytes)',
        'part_size': 67108864,
        'osos_len': 0x735A00,
        'input': 'ipod5g_fw_backup.bin',
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
        },
    },
}

def fail(msg):
    sys.exit(f'ERROR: {msg}\nNothing was written.')

def osos_info(buf, m):
    if len(buf) != m['part_size']:
        other = [k for k, v in MODELS.items() if v['part_size'] == len(buf)]
        hint = f' (that is the size of a {other[0].upper()} dump: use {"--5g" if other[0] == "5g" else "no --5g"})' if other else ''
        fail(f'input is {len(buf)} bytes, expected {m["part_size"]} for {m["name"]}{hint}')
    if buf[0x100:0x104] != b']ih[':
        fail('no "]ih[" firmware header at 0x100; this is not an iPod firmware partition')
    dir_off, _, ver = struct.unpack_from('<IHH', buf, 0x104)
    if (dir_off, ver) != (0x4000, 3) or buf[ENTRY + 4:ENTRY + 8] != b'soso':
        fail(f'unexpected image directory (dir_off=0x{dir_off:x}, version={ver})')
    devoff, length = struct.unpack_from('<II', buf, ENTRY + 12)
    start = devoff + 0x200
    if length != m['osos_len']:
        fail(f'osos length is 0x{length:x}, expected 0x{m["osos_len"]:x}; this is not {m["name"]}')
    stored = struct.unpack_from('<I', buf, CHK_OFF)[0]
    calc = sum(buf[start:start + length]) & 0xFFFFFFFF
    if stored != calc:
        fail(f'osos checksum invalid (stored 0x{stored:08x}, calculated 0x{calc:08x}); corrupt dump?')
    return start, length, stored

def state(buf, p):
    """'original', 'applied' or 'mismatch' for one patch."""
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
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--5g', dest='g5', action='store_true', help='iPod Video 5th gen instead of 4th gen')
    ap.add_argument('-i', '--input')
    ap.add_argument('-o', '--output')
    ap.add_argument('--labels', action='store_true', help='English "Genres" -> "Labels"')
    ap.add_argument('--composers', action='store_true', help='Genre/Label list opens Composers instead of Artists')
    ap.add_argument('--producers', action='store_true', help='English "Composers" -> "Producers"')
    ap.add_argument('--check', action='store_true', help='only inspect the input and report')
    ap.add_argument('--find', metavar='TEXT', help='read-only: list every occurrence of TEXT in the osos image')
    a = ap.parse_args()
    m = MODELS['5g' if a.g5 else '4g']
    patches = m['patches']
    a.input = a.input or os.path.join(root, 'firmware', m['input'])
    a.output = a.output or os.path.join(root, 'firmware', m['output'])

    orig = open(a.input, 'rb').read()
    start, length, chk = osos_info(orig, m)
    if a.find:
        find(orig, start, length, a.find)
        return
    print(f'model : {m["name"]}')
    print(f'input : {a.input}')
    print(f'sha256: {hashlib.sha256(orig).hexdigest()}')
    print(f'osos  : 0x{length:x} bytes, checksum 0x{chk:08x} (valid)')
    states = {n: state(orig, p) for n, p in patches.items()}
    for n, s in states.items():
        print(f'patch {n:10s}: {s}')
    if a.check:
        bad = [n for n, s in states.items() if s == 'mismatch']
        if bad:
            sys.exit(f'\nNot patchable: {", ".join(bad)} location(s) contain unexpected bytes.')
        print('\nOK: patchable.')
        return

    wanted = [n for n in patches if getattr(a, n)]
    if not wanted:
        fail('choose at least one patch: --labels, --composers, --producers (or --check / --find)')
    for n in wanted:
        if states[n] == 'mismatch':
            fail(f'patch "{n}": the firmware does not contain the expected bytes')
    if os.path.exists(a.output):
        fail(f'{a.output} already exists; refusing to overwrite')

    buf = bytearray(orig)
    allowed = set(range(CHK_OFF, CHK_OFF + 4))
    for n in wanted:
        for o, old, new in patches[n]['edits']:
            if not (start <= o and o + len(new) <= start + length):
                fail(f'0x{o:x} is outside the osos image')
            buf[o:o + len(new)] = new
            allowed |= set(range(o, o + len(new)))
    new_chk = sum(buf[start:start + length]) & 0xFFFFFFFF
    struct.pack_into('<I', buf, CHK_OFF, new_chk)

    # Verify: same size, only the intended bytes changed, checksum consistent.
    diff = [i for i in range(len(orig)) if orig[i] != buf[i]]
    if len(buf) != m['part_size'] or not set(diff) <= allowed:
        fail('verification failed: unexpected bytes changed')
    if osos_info(bytes(buf), m)[2] != new_chk:
        fail('verification failed: checksum')

    with open(a.output, 'wb') as f:
        f.write(buf)
    os.chmod(a.output, 0o444)
    sha = hashlib.sha256(buf).hexdigest()
    with open(a.output + '.sha256', 'w') as f:
        f.write(f'{sha}  {os.path.basename(a.output)}\n')
    print(f'\napplied: {", ".join(wanted)}')
    print(f'osos checksum 0x{chk:08x} -> 0x{new_chk:08x} (at 0x{CHK_OFF:x})')
    print(f'{len(diff)} bytes changed:')
    for i in diff:
        print(f'  0x{i:06x}: {orig[i]:02x} -> {buf[i]:02x}')
    print(f'wrote {a.output}\nsha256 {sha}')

if __name__ == '__main__':
    main()
