#!/usr/bin/env python3
"""Change the iPod's firmware from one image to another, without sudo or Terminal.

Used by the Clickwheel app. The app asks macOS for a read-write handle to the raw firmware partition
through /usr/libexec/authopen (the standard macOS password dialog) and passes that handle as stdin.
This script never opens the device itself.

  write_fd.py prepare MODEL diskNsM                     checks the partition and the model; unmounts
  write_fd.py write   MODEL diskNsM TO.bin FROM.bin     < /dev/rdiskNsM (read-write)

FROM is the iPod's firmware as it is now (the app reads it right before, with backup_fd.py dump);
TO is the image built from it by patch.py. Only the 512-byte sectors in which they differ are
written (write_sectors.apply), all inside the osos area, or inside the aupd image for a change there
(the iPod photo's boot logo); every other byte of the partition is left alone. Before writing, the
iPod must hold FROM (sectors that already hold TO are fine, e.g. after an interrupted run);
afterwards everything up to the end of the last changed image is read back and must equal TO.
To undo, write the other way round. Both images must match their .sha256 and the partition size.
Ends with "OK: firmware partition now matches".
"""
import hashlib
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    # -I (isolated mode) leaves the script's own folder off sys.path, so load siblings by path.
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fd_common = _load("backup_fd")       # partition, model and handle checks
write_sectors = _load("write_sectors")
die = fd_common.die

ENTRY = 0x4200                       # first image-directory entry (osos), as in patch.py
SEC = 512


def load_image(path, size):
    """Read an image after checking its .sha256 and size."""
    if not (os.path.isfile(path) and os.path.isfile(path + ".sha256")):
        die(f"ABORT: {path} or {path}.sha256 missing")
    data = open(path, "rb").read()
    want = open(path + ".sha256").read().split()[0]
    if hashlib.sha256(data).hexdigest() != want:
        die(f"ABORT: {path} does not match its .sha256")
    if len(data) != size:
        die(f"ABORT: {path} has the wrong size")
    return data


def osos_end(img, name):
    """End of the osos image in the partition, rounded up to a sector (from the image directory)."""
    if img[0x100:0x104] != b"]ih[" or img[ENTRY + 4:ENTRY + 8] != b"soso":
        die(f"ABORT: {name} has no iPod firmware directory")
    devoff, length = struct.unpack_from("<II", img, ENTRY + 12)
    end = devoff + 0x200 + length
    return (end + SEC - 1) // SEC * SEC


def images(img):
    """The image directory: {type: (start, end)} in partition offsets (end rounded up to a sector)."""
    out = {}
    for i in range(16):
        e = ENTRY + 40 * i
        typ = img[e + 4:e + 8][::-1]
        if not typ.strip(b"\0") or not all(32 < c < 127 for c in typ):
            break
        devoff, length = struct.unpack_from("<II", img, e + 12)
        out[typ.decode()] = (devoff + 0x200, (devoff + 0x200 + length + SEC - 1) // SEC * SEC)
    return out


def write_limit(a, b, name):
    """How far write_sectors may write and must read back: the end of osos, or the end of aupd when a
    sector inside aupd differs. A difference anywhere else (another image, free space) is refused."""
    limit = osos_end(b, name)
    imgs = images(b)
    if images(a) != imgs:
        die("ABORT: the two images have a different image directory; wrong model?")
    aupd = imgs.get("aupd")
    for s in range(limit, len(b), SEC):
        if a[s:s + SEC] != b[s:s + SEC]:
            if not (aupd and aupd[0] // SEC * SEC <= s < aupd[1]):
                die(f"ABORT: the images differ at 0x{s:x}, outside osos and aupd; refusing")
            limit = aupd[1]
    for typ, (start, end) in imgs.items():
        if typ not in ("osos", "aupd") and start < limit:
            die(f"ABORT: the {typ} image lies inside the area to be written; refusing")
    return limit


def prepare(model, part):
    disk = fd_common.check_partition(model, part)
    fd_common.check_model(model, part)
    # Nothing on the iPod may be mounted while reading or writing.
    fd_common.unmount(disk)
    print("OK: ready", flush=True)


def write(model, part, to, frm):
    size = fd_common.MODELS[model][1]
    to, frm = os.path.abspath(to), os.path.abspath(frm)
    b = load_image(to, size)
    a = load_image(frm, size)
    if osos_end(a, os.path.basename(frm)) != osos_end(b, os.path.basename(to)):
        die("ABORT: the two images have a different osos layout; wrong model?")
    limit = write_limit(a, b, os.path.basename(to))
    fd_common.check_partition(model, part)
    fd_common.check_handle(part, writable=True)
    print(f"Changing /dev/r{part} from {os.path.basename(frm)} to {os.path.basename(to)}", flush=True)
    write_sectors.apply(0, a, b, limit, os.path.basename(frm), os.path.basename(to))
    print(f"OK: firmware partition now matches {os.path.basename(to)} (up to 0x{limit:x}; rest untouched)", flush=True)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "prepare" and sys.argv[2] in fd_common.MODELS:
        prepare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == "write" and sys.argv[2] in fd_common.MODELS:
        write(*sys.argv[2:6])
    else:
        die(__doc__.strip())


if __name__ == "__main__":
    main()
