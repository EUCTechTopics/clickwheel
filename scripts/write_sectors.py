#!/usr/bin/env python3
"""Change an iPod firmware partition from image FROM to image TO by writing only the 512-byte
sectors in which they differ. Used by write_fw_5g.sh / write_fw_photo.sh (run as root) and, via apply(), by write_fd.py.

Usage: write_sectors.py FROM.bin TO.bin /dev/rdiskNsM LIMIT

Safety:
- every differing sector must lie below LIMIT (the end of the osos image, or of the aupd image for
  the iPod photo's boot logo), so the rest of the partition (the hibernation image etc.) is never written;
- before writing, the device's region [0, LIMIT) must equal FROM, except that differing sectors may
  already hold TO (e.g. after an interrupted run). Anything else aborts without writing;
- afterwards the whole region [0, LIMIT) is read back and must equal TO.
"""
import os, sys

SEC = 512
CHUNK = 1 << 20

def read_region(fd, limit):
    out = bytearray()
    pos = 0
    while pos < limit:
        n = min(CHUNK, limit - pos)
        b = os.pread(fd, n, pos)
        if len(b) != n:
            sys.exit(f'ABORT: short read at 0x{pos:x}')
        out += b
        pos += n
    return bytes(out)

def apply(fd, a, b, limit, src_name, dst_name):
    """Change the device behind the open descriptor fd from image bytes a to image bytes b
    (see the module docstring for the checks). Exits with an ABORT/MISMATCH message on failure."""
    if len(a) != len(b) or limit % SEC or limit > len(a):
        sys.exit('ABORT: images differ in size or bad limit')
    diff = [s for s in range(0, len(a), SEC) if a[s:s + SEC] != b[s:s + SEC]]
    if not diff:
        sys.exit('ABORT: the two images are identical; nothing to write')
    if any(s >= limit for s in diff):
        sys.exit(f'ABORT: images differ beyond 0x{limit:x}; refusing')
    if len(diff) > 160:      # menu patches: a few; boot logo: 20-31; a custom picture: 40
        sys.exit(f'ABORT: {len(diff)} sectors differ; expected at most 160')

    cur = read_region(fd, limit)
    dset = set(diff)
    for s in range(0, limit, SEC):
        c = cur[s:s + SEC]
        if s in dset:
            if c != a[s:s + SEC] and c != b[s:s + SEC]:
                sys.exit(f'ABORT: device sector 0x{s:x} matches neither image; nothing written')
        elif c != a[s:s + SEC]:
            sys.exit(f'ABORT: device differs from {src_name} at 0x{s:x}; nothing written')
    todo = [s for s in diff if cur[s:s + SEC] != b[s:s + SEC]]
    print(f'{len(diff)} sector(s) differ between the images; {len(todo)} to write:', flush=True)
    for s in diff:
        print(f'  0x{s:07x}' + ('' if s in todo else '  (already done)'), flush=True)
    for s in todo:
        if os.pwrite(fd, b[s:s + SEC], s) != SEC:
            sys.exit(f'WRITE FAILED at 0x{s:x} - do not unplug; run the rollback')
    os.fsync(fd)
    back = read_region(fd, limit)
    if back != b[:limit]:
        bad = [s for s in range(0, limit, SEC) if back[s:s + SEC] != b[s:s + SEC]]
        sys.exit(f'READBACK MISMATCH at {len(bad)} sector(s), first 0x{bad[0]:x} - do not unplug; run the rollback')
    print(f'readback of 0x0-0x{limit:x} matches {dst_name}', flush=True)

def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src, dst, dev, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0)
    a = open(src, 'rb').read()
    b = open(dst, 'rb').read()
    fd = os.open(dev, os.O_RDWR)
    try:
        apply(fd, a, b, limit, os.path.basename(src), os.path.basename(dst))
    finally:
        os.close(fd)

if __name__ == '__main__':
    main()
