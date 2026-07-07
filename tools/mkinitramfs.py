#!/usr/bin/env python3
"""mkinitramfs.py — build the TC8 boot ramdisk (gzipped newc cpio).

Deliberately tiny and dependency-free (python3 stdlib only, mirroring
mkbootimg.py/mksparse.py): the initramfs contains exactly

    /init           the boot-selector script (initramfs/init)
    /bin/busybox    static aarch64 busybox (extracted from the rootfs tarball)
    /dev/console    c 5 1   (kernel opens this for /init's stdio)
    /dev/null       c 1 3
    + empty dirs    /proc /sys /dev /bin /lower /rw /newroot /persist /mnt

USAGE
    mkinitramfs.py --init PATH --busybox PATH --out initramfs.cpio.gz

The output is deterministic (mtime 0, fixed inode order) so rebuilding from
identical inputs is byte-identical.
"""

import argparse
import gzip
import struct
import sys

CPIO_MAGIC = b"070701"


class Cpio:
    def __init__(self):
        self.blob = bytearray()
        self.ino = 720  # arbitrary, fixed base -> deterministic output

    def _entry(self, name, mode, filesize, rdev_maj=0, rdev_min=0, nlink=1,
               data=b""):
        self.ino += 1
        hdr = (
            CPIO_MAGIC
            + b"%08X" % self.ino          # c_ino
            + b"%08X" % mode              # c_mode
            + b"%08X" % 0                 # c_uid
            + b"%08X" % 0                 # c_gid
            + b"%08X" % nlink             # c_nlink
            + b"%08X" % 0                 # c_mtime
            + b"%08X" % filesize          # c_filesize
            + b"%08X" % 0                 # c_devmajor
            + b"%08X" % 0                 # c_devminor
            + b"%08X" % rdev_maj          # c_rdevmajor
            + b"%08X" % rdev_min          # c_rdevminor
            + b"%08X" % (len(name) + 1)   # c_namesize (incl. NUL)
            + b"%08X" % 0                 # c_check (always 0 for 070701)
        )
        self.blob += hdr + name.encode() + b"\0"
        self._pad4()
        self.blob += data
        self._pad4()

    def _pad4(self):
        self.blob += b"\0" * (-len(self.blob) % 4)

    def dir(self, name, mode=0o755):
        self._entry(name, 0o040000 | mode, 0, nlink=2)

    def file(self, name, data, mode=0o755):
        self._entry(name, 0o100000 | mode, len(data), data=data)

    def chardev(self, name, major, minor, mode=0o600):
        self._entry(name, 0o020000 | mode, 0, rdev_maj=major, rdev_min=minor)

    def trailer(self):
        self._entry("TRAILER!!!", 0, 0)
        # pad archive to 512 for tidiness (kernel doesn't require it)
        self.blob += b"\0" * (-len(self.blob) % 512)
        return bytes(self.blob)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", required=True, help="init script (POSIX sh)")
    ap.add_argument("--busybox", required=True, help="static busybox binary")
    ap.add_argument("--out", required=True, help="output initramfs.cpio.gz")
    a = ap.parse_args()

    init = open(a.init, "rb").read()
    busybox = open(a.busybox, "rb").read()

    if not init.startswith(b"#!"):
        sys.exit("ERROR: %s does not look like a script" % a.init)
    if busybox[:4] != b"\x7fELF":
        sys.exit("ERROR: %s is not an ELF binary" % a.busybox)
    if busybox[18:20] != struct.pack("<H", 183):  # e_machine EM_AARCH64
        sys.exit("ERROR: %s is not aarch64" % a.busybox)

    c = Cpio()
    for d in ("dev", "proc", "sys", "bin", "mnt",
              "lower", "rw", "newroot", "persist"):
        c.dir(d)
    c.chardev("dev/console", 5, 1, 0o600)
    c.chardev("dev/null", 1, 3, 0o666)
    c.file("bin/busybox", busybox, 0o755)
    c.file("init", init, 0o755)
    cpio = c.trailer()

    # mtime=0 + no filename in the gzip header -> deterministic output.
    payload = gzip.compress(cpio, compresslevel=9, mtime=0)
    with open(a.out, "wb") as f:
        f.write(payload)
    print("initramfs: %d files, cpio %d B -> %s (%d B gz)"
          % (2, len(cpio), a.out, len(payload)))


if __name__ == "__main__":
    main()
