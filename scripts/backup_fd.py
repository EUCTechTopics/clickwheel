#!/usr/bin/env python3
"""Read-only backup of an iPod firmware partition, without sudo or Terminal.

Used by the Clickwheel app. The app asks macOS for a read-only handle to the raw partition through
/usr/libexec/authopen (the standard macOS password dialog) and passes that handle as stdin. This
script never opens the device itself and never writes to it: it only reads from stdin.

Two steps, same checks and output as scripts/backup_fw*.sh:
  backup_fd.py prepare MODEL diskNsM [DIR]    checks the partition and the model, unmounts the iPod
  backup_fd.py read    MODEL diskNsM [DIR]    < /dev/rdiskNsM   reads twice, compares, writes the backup
For the app (the iPod's current firmware, kept in ~/Library/Application Support/Clickwheel):
  backup_fd.py dump    MODEL diskNsM FILE     < /dev/rdiskNsM   reads twice, compares, writes FILE (+ .sha256)
And, like scripts/device_state.sh (no unmount needed, nothing is saved):
  backup_fd.py state   MODEL diskNsM          < /dev/rdiskNsM   runs patch.py --check --json on the iPod

MODEL is 4g, photo or 5g. Output: DIR/<backup file> (+ .sha256), made read-only. DIR defaults to
firmware/ in the repository (another folder is only for testing next to an existing backup).
"""
import fcntl
import hashlib
import os
import re
import stat
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = {
    "4g": ("ipod_fw_backup.bin", 33554432, "an iPod 4G (BoardHwName iPod Q21)"),
    "photo": ("ipodphoto_fw_backup.bin", 33554432, "an iPod photo/color (BoardHwName iPod P98)"),
    "5g": ("ipod5g_fw_backup.bin", 67108864, "an iPod Video (5G)"),
}
CHUNK = 1 << 20  # 1 MiB, a multiple of the 512-byte sector size


def die(msg):
    print(msg, flush=True)
    sys.exit(1)


def diskutil_info(dev):
    r = subprocess.run(["/usr/sbin/diskutil", "info", dev], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def check_partition(model, part):
    if not re.fullmatch(r"disk[0-9]+s[0-9]+", part):
        die(f"ABORT: '{part}' is not a partition name like disk4s2")
    disk = part.rsplit("s", 1)[0]
    _, size, _ = MODELS[model]
    if not re.search(r"Media Name:.*iPod", diskutil_info(disk)):
        die(f"ABORT: {disk} is not an iPod")
    info = diskutil_info(part)
    if not re.search(r"Partition Type:.*Apple_MDFW", info):
        die(f"ABORT: {part} is not Apple_MDFW")
    if f"({size} Bytes)" not in info:
        die(f"ABORT: {part} is not {size} bytes")
    return disk


OUTDIR = os.path.join(ROOT, "firmware")


def out_path(model):
    return os.path.join(OUTDIR, MODELS[model][0])


def check_model(model, part):
    """SysInfo-based model check; needs the iPod's data volume mounted (else 'unknown' is accepted)."""
    found = subprocess.run([os.path.join(ROOT, "scripts", "ipod_model.sh"), part],
                           capture_output=True, text=True).stdout.strip()
    if found not in (model, "unknown"):
        die(f"ABORT: this iPod is identified as '{found}', not {MODELS[model][2]}.")


def unmount(disk):
    r = subprocess.run(["/usr/sbin/diskutil", "unmountDisk", f"/dev/{disk}"], capture_output=True, text=True)
    print((r.stdout + r.stderr).strip(), flush=True)
    if r.returncode != 0:
        die("ABORT: could not unmount the iPod")


def check_handle(part, writable, fd=0):
    """The handle (stdin) must be the raw device of exactly this partition, opened as expected."""
    st = os.fstat(fd)
    raw = os.stat(f"/dev/r{part}")
    if not (stat.S_ISCHR(st.st_mode) and st.st_rdev == raw.st_rdev):
        kind = "char" if stat.S_ISCHR(st.st_mode) else "block" if stat.S_ISBLK(st.st_mode) else \
               "file" if stat.S_ISREG(st.st_mode) else "pipe" if stat.S_ISFIFO(st.st_mode) else \
               "socket" if stat.S_ISSOCK(st.st_mode) else oct(st.st_mode)
        die(f"ABORT: the handle Clickwheel received is not /dev/r{part} "
            f"(got {kind} {st.st_rdev:#x}; want char {raw.st_rdev:#x})")
    mode = fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE
    if mode != (os.O_RDWR if writable else os.O_RDONLY):
        die(f"ABORT: expected a {'read-write' if writable else 'read-only'} handle")


def prepare(model, part):
    disk = check_partition(model, part)
    out = out_path(model)
    if os.path.exists(out):
        die(f"ABORT: {out} already exists; refusing to overwrite your backup.")
    check_model(model, part)
    # Nothing on the iPod may be mounted while we read it.
    unmount(disk)
    print("OK: ready to read", flush=True)


def read_all(fd, size, h, sink=None):
    """Read the whole partition from offset 0 with pread (the handle may be shared)."""
    off = 0
    while off < size:
        buf = os.pread(fd, min(CHUNK, size - off), off)
        if not buf:
            break
        h.update(buf)
        if sink:
            sink.write(buf)
        off += len(buf)
        if off % (8 * CHUNK) == 0 or off == size:
            print(f"progress: {off} / {size}", flush=True)
    return off


def read_verified(part, size, out, ok_line, replace=False):
    """Read the partition from the handle on stdin into `out` twice and compare. The file is only put
    in place (read-only, with a .sha256) when both reads and the saved file agree."""
    tmp = out + ".partial"
    if os.path.exists(tmp):
        os.unlink(tmp)
    print(f"Reading /dev/r{part} -> {out}", flush=True)
    h1 = hashlib.sha256()
    try:
        with open(tmp, "xb") as f:
            got = read_all(0, size, h1, f)
        print(f"size: {got} (expected {size})", flush=True)
        if got != size:
            die("SIZE MISMATCH")
        h2 = hashlib.sha256()
        print("Reading the iPod a second time to compare", flush=True)
        read_all(0, size, h2)
        print(f"sha256 first read  : {h1.hexdigest()}", flush=True)
        print(f"sha256 second read : {h2.hexdigest()}", flush=True)
        if h1.hexdigest() != h2.hexdigest():
            die("CHECKSUM MISMATCH between the two reads")
        # Check the file on disk too, not just what we meant to write.
        h3 = hashlib.sha256()
        with open(tmp, "rb") as f:
            for b in iter(lambda: f.read(CHUNK), b""):
                h3.update(b)
        if h3.hexdigest() != h1.hexdigest():
            die("CHECKSUM MISMATCH between the read and the saved file")
        os.chmod(tmp, 0o444)
        if replace:
            if os.path.exists(out):
                os.chmod(out, 0o644)
            os.replace(tmp, out)
        else:
            os.link(tmp, out)  # fails instead of replacing if a backup appeared meanwhile
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)  # after os.link this only drops the second name; the file stays read-only
    with open(out + ".sha256", "w") as f:
        f.write(f"{h1.hexdigest()}  {os.path.basename(out)}\n")
    print(ok_line, flush=True)


def read(model, part):
    """The repository's safety copy (firmware/<backup file>); never overwrites one."""
    check_partition(model, part)
    check_handle(part, writable=False)
    os.makedirs(OUTDIR, exist_ok=True)
    out = out_path(model)
    if os.path.exists(out):
        die(f"ABORT: {out} already exists; refusing to overwrite your backup.")
    read_verified(part, MODELS[model][1], out, "OK: backup verified")


def dump(model, part, out):
    """The iPod's firmware as it is now, into `out` (the app keeps it in ~/Library/Application
    Support/Clickwheel). Replaces an older copy at that path, never anything in firmware/."""
    check_partition(model, part)
    check_handle(part, writable=False)
    out = os.path.abspath(out)
    if os.path.realpath(os.path.dirname(out)) == os.path.realpath(os.path.join(ROOT, "firmware")):
        die("ABORT: dump never writes into firmware/ (that's where the safety copies live)")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    read_verified(part, MODELS[model][1], out, "OK: read verified", replace=True)


def state(model, part):
    """Read-only: which patches are on the iPod now. Reads into a temp file, runs patch.py --check."""
    import tempfile
    check_partition(model, part)
    check_model(model, part)
    check_handle(part, writable=False)
    size = MODELS[model][1]
    fd, tmp = tempfile.mkstemp(prefix="clickwheel-state-")
    try:
        print(f"Reading /dev/r{part} (read-only)", flush=True)
        with os.fdopen(fd, "wb") as f:
            got = read_all(0, size, hashlib.sha256(), f)
        if got != size:
            die(f"ABORT: read {got} of {size} bytes")
        r = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts", "patch.py"),
                            "--model", model, "--check", "-i", tmp, "--json"], capture_output=True, text=True)
        print(r.stdout.strip(), flush=True)
        if r.stderr.strip():
            print(r.stderr.strip(), flush=True)
    finally:
        os.unlink(tmp)


def main():
    global OUTDIR
    cmds = {"prepare": prepare, "read": read, "state": state, "dump": dump}
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in cmds or sys.argv[2] not in MODELS:
        die(__doc__.strip())
    if sys.argv[1] == "dump":
        if len(sys.argv) != 5:
            die(__doc__.strip())
        dump(sys.argv[2], sys.argv[3], sys.argv[4])
        return
    if len(sys.argv) == 5:
        OUTDIR = os.path.abspath(sys.argv[4])
    cmds[sys.argv[1]](sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    main()
