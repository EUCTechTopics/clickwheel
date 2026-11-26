#!/usr/bin/env python3
"""Read-only: check that a firmware partition (device or file) and an image are the same model, by
comparing the osos entry of their image directories (length at partition 0x4210).
Usage: same_model.py /dev/rdiskNsM IMAGE.bin      (exit 0 = same model)
"""
import struct, sys

def osos_len(path):
    with open(path, 'rb') as f:
        head = f.read(0x4400)
    if len(head) < 0x4400 or head[0x100:0x104] != b']ih[' or head[0x4204:0x4208] != b'soso':
        return None
    return struct.unpack_from('<I', head, 0x4210)[0]

if len(sys.argv) != 3:
    sys.exit(__doc__)
dev, img = osos_len(sys.argv[1]), osos_len(sys.argv[2])
if img is None:
    sys.exit(f'ABORT: {sys.argv[2]} has no iPod firmware directory')
if dev is None:
    sys.exit(f'ABORT: {sys.argv[1]} holds no readable iPod firmware directory; refusing to write blind')
if dev != img:
    sys.exit(f'ABORT: the iPod holds a different firmware (osos 0x{dev:x} bytes) than the image (0x{img:x}); wrong model?')
print(f'same model: osos 0x{img:x} bytes on both')
