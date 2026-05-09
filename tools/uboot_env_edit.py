#!/usr/bin/env python3
"""u-boot env editor for TC8 — read existing block, modify entries, write back with CRC.

The TC8 panel keeps its u-boot environment in a single 4096-byte block on
/dev/mmcblk2 at offset 0x400000 (sector 1024 with bs=4096). The block layout:

    [0x000..0x004)  little-endian CRC32 of bytes [0x004..0x1000)
    [0x004..0x1000) NUL-separated key=value entries, padded with 0x00

The CRC is the standard zlib CRC32 (poly 0xEDB88320, init/xorout 0xFFFFFFFF),
matching python's zlib.crc32 directly.

Usage:
    uboot_env_edit.py read  [<host>] [<out.bin>]
    uboot_env_edit.py show  <in.bin>
    uboot_env_edit.py modify <in.bin> <out.bin> <key=value> [<key=value>...]
    uboot_env_edit.py delete <in.bin> <out.bin> <key> [<key>...]
    uboot_env_edit.py preset-symmetric <in.bin> <out.bin>
    uboot_env_edit.py verify <in.bin>

`read` shells out to ssh on the panel (default: root@192.168.10.244) and
dumps the env block locally. It does NOT write back.

`preset-symmetric` produces an env that:
    - Adds slotaboot mirroring slotbboot but for slot _a (boot_a/dtbo_a sectors).
    - Rewrites slotbboot to use androidboot.slot_suffix=_b instead of root=,
      and adds console=tty0 plus rw rootwait.
    - Adds bootcmd_ab that picks slotaboot/slotbboot based on $slot env var,
      falling back to the NXP A/B-aware `boota mmc1`.
    - Sets default `slot=b` (current convention).
"""

from __future__ import annotations

import os
import struct
import subprocess
import sys
import zlib

ENV_BLOCK_SIZE = 4096
ENV_DATA_SIZE = ENV_BLOCK_SIZE - 4

DEFAULT_HOST = "root@192.168.10.244"
PANEL_DD_READ = "dd if=/dev/mmcblk2 bs=4096 skip=1024 count=1 2>/dev/null"

# ---------------------------------------------------------------------------
# Slot/boot constants — derived from the panel's GPT.
#
#   p1 dtbo_a  start sector 0x4000
#   p2 dtbo_b  start sector 0x6000
#   p3 boot_a  start sector 0x8000
#   p4 boot_b  start sector 0x20000
#
# Sizes (in sectors of 512B):
#   boot.img read length = 0x14800 sectors (~41 MiB; covers any boot.img we ship)
#   dtbo    read length = 0x100   sectors (128 KiB; well over our dtb size)
# ---------------------------------------------------------------------------

BOOT_A_LBA = 0x8000
BOOT_B_LBA = 0x20000
DTBO_A_LBA = 0x4000
DTBO_B_LBA = 0x6000
BOOT_LEN = 0x14800
DTBO_LEN = 0x100

KERNEL_LOAD = 0x40000000
DTB_LOAD = 0x43400000
BOOTI_KERNEL = 0x40000800  # skip 2 KiB android boot header

COMMON_BOOTARGS = (
    "console=tty0 console=ttymxc1,115200 "
    "earlycon=ec_imx6q,0x30890000,115200 keep_bootcon panic=10"
)


def _slot_macro(suffix: str, boot_lba: int, dtbo_lba: int) -> str:
    return (
        f"mmc dev 1; "
        f"mmc read {KERNEL_LOAD:#x} {boot_lba:#x} {BOOT_LEN:#x}; "
        f"mmc read {DTB_LOAD:#x} {dtbo_lba:#x} {DTBO_LEN:#x}; "
        f'setenv bootargs "{COMMON_BOOTARGS} '
        f'androidboot.slot_suffix={suffix} rw rootwait"; '
        f"booti {BOOTI_KERNEL:#x} - {DTB_LOAD:#x}"
    )


SLOTABOOT = _slot_macro("_a", BOOT_A_LBA, DTBO_A_LBA)
SLOTBBOOT = _slot_macro("_b", BOOT_B_LBA, DTBO_B_LBA)
# Pick by $slot, fall back to NXP boota which honors AOSP misc slot priority.
BOOTCMD_AB = (
    'if test "${slot}" = "a"; then run slotaboot; fi; '
    "run slotbboot; "
    "boota mmc1"
)


# ---------------------------------------------------------------------------
# env block parsing / serialisation
# ---------------------------------------------------------------------------


def parse_env(block: bytes) -> "dict[str, str]":
    if len(block) != ENV_BLOCK_SIZE:
        raise ValueError(f"env block must be {ENV_BLOCK_SIZE} bytes, got {len(block)}")
    stored_crc = struct.unpack("<I", block[:4])[0]
    payload = block[4:]
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if stored_crc != actual_crc:
        sys.stderr.write(
            f"warning: stored CRC {stored_crc:#010x} != computed {actual_crc:#010x}\n"
        )
    out: "dict[str, str]" = {}
    # Entries are NUL-terminated key=value strings; empty entry signals end.
    for entry in payload.split(b"\x00"):
        if not entry:
            break
        try:
            text = entry.decode("ascii")
        except UnicodeDecodeError:
            text = entry.decode("latin-1")
        if "=" not in text:
            sys.stderr.write(f"warning: malformed entry (no '='): {text!r}\n")
            continue
        k, v = text.split("=", 1)
        out[k] = v
    return out


def serialize_env(entries: "dict[str, str]") -> bytes:
    # Deterministic order: keep insertion order of the dict.
    parts = [f"{k}={v}".encode("ascii") for k, v in entries.items()]
    payload = b"\x00".join(parts) + b"\x00\x00"  # final entry NUL + empty NUL
    if len(payload) > ENV_DATA_SIZE:
        raise ValueError(
            f"env payload {len(payload)} > {ENV_DATA_SIZE} bytes"
        )
    payload = payload.ljust(ENV_DATA_SIZE, b"\x00")
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    return struct.pack("<I", crc) + payload


def verify_block(block: bytes) -> "tuple[bool, str]":
    if len(block) != ENV_BLOCK_SIZE:
        return False, f"size={len(block)} (want {ENV_BLOCK_SIZE})"
    stored = struct.unpack("<I", block[:4])[0]
    actual = zlib.crc32(block[4:]) & 0xFFFFFFFF
    if stored != actual:
        return False, f"crc stored={stored:#010x} actual={actual:#010x}"
    # Walk entries, ensure all well-formed.
    for entry in block[4:].split(b"\x00"):
        if not entry:
            break
        try:
            text = entry.decode("ascii")
        except UnicodeDecodeError:
            return False, f"non-ascii entry: {entry!r}"
        if "=" not in text:
            return False, f"malformed entry: {text!r}"
    return True, "ok"


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------


def cmd_read(argv: "list[str]") -> int:
    host = argv[0] if len(argv) >= 1 else DEFAULT_HOST
    out_path = argv[1] if len(argv) >= 2 else "/tmp/env_orig.bin"
    cmd = ["ssh", host, PANEL_DD_READ]
    sys.stderr.write(f"+ {' '.join(cmd)}\n")
    res = subprocess.run(cmd, capture_output=True, check=False)
    if res.returncode != 0:
        sys.stderr.write(res.stderr.decode("utf-8", "replace"))
        return res.returncode
    block = res.stdout
    if len(block) != ENV_BLOCK_SIZE:
        sys.stderr.write(
            f"error: dd returned {len(block)} bytes, expected {ENV_BLOCK_SIZE}\n"
        )
        return 1
    with open(out_path, "wb") as f:
        f.write(block)
    ok, msg = verify_block(block)
    sys.stderr.write(f"wrote {out_path} ({len(block)} bytes) — verify: {msg}\n")
    return 0 if ok else 2


def cmd_show(argv: "list[str]") -> int:
    if len(argv) < 1:
        sys.stderr.write("usage: show <in.bin>\n")
        return 2
    with open(argv[0], "rb") as f:
        block = f.read()
    entries = parse_env(block)
    for k, v in entries.items():
        print(f"{k}={v}")
    sys.stderr.write(
        f"\n# {len(entries)} entries, payload "
        f"{sum(len(k)+len(v)+2 for k, v in entries.items())} bytes\n"
    )
    return 0


def _load(path: str) -> "dict[str, str]":
    with open(path, "rb") as f:
        return parse_env(f.read())


def _save(entries: "dict[str, str]", path: str) -> None:
    block = serialize_env(entries)
    with open(path, "wb") as f:
        f.write(block)
    ok, msg = verify_block(block)
    used = sum(len(k) + len(v) + 2 for k, v in entries.items())
    sys.stderr.write(
        f"wrote {path}: {len(entries)} entries, {used}/{ENV_DATA_SIZE} bytes "
        f"used — verify: {msg}\n"
    )


def cmd_modify(argv: "list[str]") -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: modify <in.bin> <out.bin> <key=value>...\n")
        return 2
    src, dst, *kvs = argv
    entries = _load(src)
    for kv in kvs:
        if "=" not in kv:
            sys.stderr.write(f"error: bad arg {kv!r} (need key=value)\n")
            return 2
        k, v = kv.split("=", 1)
        entries[k] = v
    _save(entries, dst)
    return 0


def cmd_delete(argv: "list[str]") -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: delete <in.bin> <out.bin> <key>...\n")
        return 2
    src, dst, *keys = argv
    entries = _load(src)
    for k in keys:
        entries.pop(k, None)
    _save(entries, dst)
    return 0


def cmd_preset_symmetric(argv: "list[str]") -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: preset-symmetric <in.bin> <out.bin>\n")
        return 2
    src, dst = argv[0], argv[1]
    if os.path.exists(src):
        entries = _load(src)
    else:
        sys.stderr.write(f"note: {src} missing — starting from empty env\n")
        entries = {}
    entries["slotaboot"] = SLOTABOOT
    entries["slotbboot"] = SLOTBBOOT
    entries["bootcmd_ab"] = BOOTCMD_AB
    entries.setdefault("slot", "b")
    _save(entries, dst)
    sys.stderr.write("\n--- slotaboot ---\n" + entries["slotaboot"] + "\n")
    sys.stderr.write("\n--- slotbboot ---\n" + entries["slotbboot"] + "\n")
    sys.stderr.write("\n--- bootcmd_ab ---\n" + entries["bootcmd_ab"] + "\n")
    return 0


def cmd_verify(argv: "list[str]") -> int:
    if len(argv) < 1:
        sys.stderr.write("usage: verify <in.bin>\n")
        return 2
    with open(argv[0], "rb") as f:
        block = f.read()
    ok, msg = verify_block(block)
    print(f"{'OK' if ok else 'FAIL'}: {msg}")
    entries = parse_env(block) if ok else {}
    must_have = ("slotaboot", "slotbboot")
    missing = [k for k in must_have if k not in entries]
    if missing:
        print(f"missing keys: {missing}")
        ok = False
    return 0 if ok else 1


SUBCOMMANDS = {
    "read": cmd_read,
    "show": cmd_show,
    "modify": cmd_modify,
    "delete": cmd_delete,
    "preset-symmetric": cmd_preset_symmetric,
    "verify": cmd_verify,
}


def main(argv: "list[str]") -> int:
    if len(argv) < 1 or argv[0] in ("-h", "--help", "help"):
        sys.stderr.write(__doc__ or "")
        return 0
    sub = argv[0]
    if sub not in SUBCOMMANDS:
        sys.stderr.write(f"unknown subcommand: {sub}\n")
        sys.stderr.write(__doc__ or "")
        return 2
    return SUBCOMMANDS[sub](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
