#!/usr/bin/env python3
"""Read-only: print the USB product ID of the iPod behind a disk (e.g. disk6 or disk6s2), or nothing.

The iPod nano (1st gen, 4618 = 0x120A) and the iPod Video 5G (4617 = 0x1209) have firmware partitions
of the same size and often an empty SysInfo, so ipod_model.sh and the app tell them apart by this.
Walks the IORegistry (ioreg -a): the USB device whose subtree holds an IOMedia with that BSD name.
Usage: usb_product.py diskN[sM]
"""
import plistlib, re, subprocess, sys


def product_for(disk):
    disk = re.sub(r's[0-9]+$', '', disk)
    try:
        out = subprocess.run(['/usr/sbin/ioreg', '-a', '-r', '-c', 'IOUSBHostDevice', '-l'],
                             capture_output=True, timeout=10).stdout
        roots = plistlib.loads(out) if out else []
    except Exception:
        return None

    def holds(node):
        if node.get('BSD Name') == disk:
            return True
        return any(holds(c) for c in node.get('IORegistryEntryChildren', []))

    for dev in roots:
        if dev.get('idVendor') == 1452 and holds(dev):      # Apple
            return dev.get('idProduct')
    return None


if __name__ == '__main__':
    if len(sys.argv) != 2 or not re.fullmatch(r'disk[0-9]+(s[0-9]+)?', sys.argv[1]):
        sys.exit(__doc__)
    p = product_for(sys.argv[1])
    if p is not None:
        print(p)
