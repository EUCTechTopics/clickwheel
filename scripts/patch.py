#!/usr/bin/env python3
"""Build a patched iPod firmware image from a backup. Never touches the device.

Supported (--model, default 4g):
  4g     iPod 4th gen click wheel (iPod Q21), firmware 3.1.1
  5g     iPod Video 5th gen, the build in the user's backup          (--5g is short for --model 5g)
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
  --logo       iPod photo and iPod Video: the boot Apple logo upside down (in the encrypted aupd image)

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
                # Boot logo (iPodWizard picture index 417) in the encrypted aupd image, as on the iPod photo.
                # The delta is the XOR of the stock and the iPodWizard-flipped bytes (tested on a device);
                # unlike the photo, the 5G's aupd checksum field changes with it.
                'desc': 'Boot Apple logo (in aupd) upside down',
                'xor': {'image': 'aupd', 'offset': 0xCF9E5C, 'length': 9552, 'delta': '5g_logo.xor',
                        'delta_sha256': 'c1921e6edd619643d1cb900b1f248b0d036a0af7832b716f9c743b23a07a83f3',
                        'original_sha256': '822498a8b4a3612292b0be415ac33274a47646517e1e0468c091299840902d05',
                        'applied_sha256': '9f21a07a49f2c46428fdf5277e85ec9f625c8057d1d3f2483105560a2cd53bcc',
                        # aupd checksum in its directory entry: stock -> flipped
                        'checksum': (0x426C, bytes.fromhex('1cdb190b'), bytes.fromhex('5c3b1a0b'))},
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
            'logo': {
                # The 78x100 RGB565 boot logo lives in the encrypted aupd image (flashed into the boot ROM),
                # not in osos. The encryption is a position-based XOR stream, so flipping the picture upside
                # down = XOR with a fixed delta (stock ^ flipped ciphertext, taken from an iPodWizard flip that
                # was tested on a device). Row reversal keeps the decrypted byte sum, so the aupd checksum
                # field stays valid; iPodWizard leaves it unchanged too.
                'desc': 'Boot Apple logo (78x100, in aupd) upside down',
                'xor': {'image': 'aupd', 'offset': 0x5DDAB4, 'length': 15600, 'delta': 'photo_logo.xor',
                        'delta_sha256': '028f5e2955fed46e94621f7747183e64c57c7011b06e43ba46a11519366c761d',
                        'original_sha256': '8bdcf822435e134db63cb4cee80ceb0f83d08ffe393bd3c9c58f47e9e02eceec',
                        'applied_sha256': 'df328b32b5689ec01b8782a5e2706b99612c100f132e294c5c61a6031b4c93a5'},
                'context': [],
            },
        },
    },
}

JSON = False


def xor_edits(buf, p):
    """Edits for an 'xor' patch, worked out from the input: the region must be exactly the original
    bytes or exactly the patched bytes (by sha256). None when neither: the patch then reports 'mismatch'."""
    x = p['xor']
    delta = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'patchdata', x['delta']), 'rb').read()
    if len(delta) != x['length'] or hashlib.sha256(delta).hexdigest() != x['delta_sha256']:
        fail(f'scripts/patchdata/{x["delta"]} is missing or damaged')
    o, n = x['offset'], x['length']
    cur = bytes(buf[o:o + n])
    other = bytes(c ^ d for c, d in zip(cur, delta))
    h = hashlib.sha256(cur).hexdigest()
    extra = [x['checksum']] if 'checksum' in x else []
    if h == x['original_sha256']:
        return [(o, cur, other)] + extra
    if h == x['applied_sha256']:
        return [(o, other, cur)] + extra
    return None

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
    start = devoff + 0x200
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
        out.append({'type': typ.decode(), 'offset': devoff + 0x200, 'length': length})
    return out

def state(buf, p):
    """'original', 'applied' or 'mismatch' for one patch."""
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
    ap.add_argument('--photo', action='store_true', help='short for --model photo')
    ap.add_argument('-i', '--input')
    ap.add_argument('-o', '--output')
    ap.add_argument('--labels', action='store_true', help='English "Genres" -> "Labels"')
    ap.add_argument('--composers', action='store_true', help='Genre/Label list opens Composers instead of Artists')
    ap.add_argument('--producers', action='store_true', help='English "Composers" -> "Producers"')
    ap.add_argument('--logo', action='store_true', help='iPod photo and iPod Video: boot Apple logo upside down')
    ap.add_argument('--reflash', action='store_true',
                    help='iPod photo and iPod Video: mark aupd as not yet flashed, so the iPod copies it into its boot ROM at the next start')
    ap.add_argument('--exact', action='store_true',
                    help='unnamed patches are removed (original bytes restored); with no patch named: remove all')
    ap.add_argument('--check', action='store_true', help='only inspect the input and report')
    ap.add_argument('--plan', action='store_true', help='show exactly what would change, but write nothing')
    ap.add_argument('--json', action='store_true', help='machine-readable output (for the Clickwheel app)')
    ap.add_argument('--find', metavar='TEXT', help='read-only: list every occurrence of TEXT in the osos image')
    a = ap.parse_args()
    JSON = a.json
    picked = [k for k, on in (('5g', a.g5), ('photo', a.photo)) if on] + ([a.model] if a.model else [])
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
    patches = {n: dict(p, edits=xor_edits(orig, p)) if 'xor' in p else p for n, p in patches.items()}
    for n in ('labels', 'composers', 'producers', 'logo'):
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

    wanted = [n for n in patches if getattr(a, n)]
    removed = [n for n in patches if a.exact and n not in wanted and states[n] != 'original']
    if not wanted and not a.exact and not a.reflash:
        fail('choose at least one patch: --labels, --composers, --producers (or --exact, --check / --find)')
    for n in wanted + removed:
        if states[n] == 'mismatch':
            fail(f'patch "{n}": the firmware does not contain the expected bytes')
    if not a.plan and os.path.exists(a.output):
        fail(f'{a.output} already exists; refusing to overwrite')

    buf = bytearray(orig)
    allowed = set(range(CHK_OFF, CHK_OFF + 4))
    imgs = {i['type']: i for i in images(orig)}

    def inside(n, o, size):
        # every edit stays in osos, or in the one other image an 'xor' patch names (e.g. aupd)
        regions = [(start, start + length)]
        name = patches[n].get('xor', {}).get('image')
        if name:
            if name not in imgs:
                fail(f'patch "{n}": no {name} image in this firmware')
            regions.append((imgs[name]['offset'], imgs[name]['offset'] + imgs[name]['length']))
            if 'checksum' in patches[n]['xor']:     # that image's checksum field in the directory
                c = patches[n]['xor']['checksum'][0]
                regions.append((c, c + 4))
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
    diff = [i for i in range(len(orig)) if orig[i] != buf[i]]
    if len(buf) != m['part_size'] or not set(diff) <= allowed:
        fail('verification failed: unexpected bytes changed')
    if osos_info(bytes(buf), m)[2] != new_chk:
        fail('verification failed: checksum')
    result = {n: state(bytes(buf), dict(p, edits=xor_edits(buf, p)) if 'xor' in p else p) for n, p in patches.items()}
    expect = {n: 'applied' if n in wanted else 'original' if n in removed else states[n] for n in patches}
    if result != expect:
        fail(f'verification failed: patch states after the build are {result}, expected {expect}')
    result_stock = (hashlib.sha256(buf[start:start + length]).hexdigest() == stock) if stock else None

    sha = hashlib.sha256(buf).hexdigest()
    report.update({'aupd_reflash': bool(flag) and buf[flag:flag + 4] == b'\0\0\0\0' and orig[flag:flag + 4] != b'\0\0\0\0',
                   'applied': wanted, 'removed': removed, 'exact': a.exact, 'result_states': result,
                   'result_stock': result_stock, 'new_checksum': new_chk, 'plan': a.plan, 'output': None if a.plan else a.output,
                   'output_sha256': sha, 'sectors': sorted({i // 512 * 512 for i in diff}),
                   'changes': [{'offset': i, 'old': orig[i], 'new': buf[i]} for i in diff]})
    if not a.plan:
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
