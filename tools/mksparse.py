#!/usr/bin/env python3
# mksparse.py — convert a raw disk image to an Android sparse image (.simg).
#
# Our rootfs.img is a plain ext4 sized for the whole `userdata` GPT partition
# (multi-GiB) but is mostly zero blocks. WebUSB fastboot can only `download` up
# to the device max-download-size at a time, and a multi-GiB raw image neither
# fits in browser memory nor in one download. The Android sparse format encodes
# the long zero runs as DONT_CARE chunks (no payload), so the on-disk .simg is a
# small fraction of the raw size; the browser then re-splits THAT into
# per-download sub-images (see provision-tool/src/sparse.js). The NXP FSL
# fastboot in our stage-2 un-sparses on its side ("support sparse flash
# partition").
#
# Pure python3 stdlib. Format per AOSP system/core/libsparse (sparse_format.h):
#
#   [28B sparse_header][ chunk_header + data ] * total_chunks
#
# Chunk types: RAW (payload = blocks verbatim), DONT_CARE (no payload — device
# skips/zeroes that span), FILL and CRC32 (unused here). All fields little-endian.
#
# CLI: mksparse.py <raw_in> <simg_out>
import struct, sys

SPARSE_MAGIC   = 0xed26ff3a
MAJOR_VERSION  = 1
MINOR_VERSION  = 0
FILE_HDR_SZ    = 28
CHUNK_HDR_SZ   = 12
BLK_SZ         = 4096

CHUNK_TYPE_RAW       = 0xCAC1
CHUNK_TYPE_FILL      = 0xCAC2
CHUNK_TYPE_DONT_CARE = 0xCAC3
CHUNK_TYPE_CRC32     = 0xCAC4


def file_header(total_blks, total_chunks):
    # sparse_header_t — 28 bytes, little-endian.
    return struct.pack(
        "<IHHHHIIII",
        SPARSE_MAGIC,    # magic
        MAJOR_VERSION,   # major_version
        MINOR_VERSION,   # minor_version
        FILE_HDR_SZ,     # file_hdr_sz
        CHUNK_HDR_SZ,    # chunk_hdr_sz
        BLK_SZ,          # blk_sz
        total_blks,      # total_blks
        total_chunks,    # total_chunks
        0,               # image_checksum (0 — device does not verify)
    )


def chunk_header(chunk_type, chunk_blks, data_len):
    # chunk_header_t — 12 bytes, little-endian. total_sz includes this header.
    return struct.pack(
        "<HHII",
        chunk_type,                    # chunk_type
        0,                             # reserved
        chunk_blks,                    # chunk_sz (in blocks)
        CHUNK_HDR_SZ + data_len,       # total_sz (bytes, incl header)
    )


def convert(raw_in, simg_out):
    with open(raw_in, "rb") as f:
        raw = f.read()
    raw_len = len(raw)
    if raw_len % BLK_SZ != 0:
        # Pad the tail block with zeros so the image is a whole number of blocks.
        raw = raw + b"\x00" * (BLK_SZ - (raw_len % BLK_SZ))
    total_blks = len(raw) // BLK_SZ
    zero_blk = b"\x00" * BLK_SZ

    # Walk the blocks, coalescing consecutive zero blocks into DONT_CARE runs and
    # consecutive non-zero blocks into RAW runs. We buffer chunks so we can write
    # the real total_chunks into the header (sparse readers rely on it).
    chunks = []   # list of (chunk_type, chunk_blks, payload_bytes_or_None)
    i = 0
    while i < total_blks:
        blk = raw[i * BLK_SZ:(i + 1) * BLK_SZ]
        if blk == zero_blk:
            j = i + 1
            while j < total_blks and raw[j * BLK_SZ:(j + 1) * BLK_SZ] == zero_blk:
                j += 1
            chunks.append((CHUNK_TYPE_DONT_CARE, j - i, None))
            i = j
        else:
            j = i + 1
            while j < total_blks and raw[j * BLK_SZ:(j + 1) * BLK_SZ] != zero_blk:
                j += 1
            chunks.append((CHUNK_TYPE_RAW, j - i, raw[i * BLK_SZ:j * BLK_SZ]))
            i = j

    with open(simg_out, "wb") as out:
        out.write(file_header(total_blks, len(chunks)))
        for ctype, cblks, payload in chunks:
            data_len = len(payload) if payload is not None else 0
            out.write(chunk_header(ctype, cblks, data_len))
            if payload is not None:
                out.write(payload)

    return total_blks, len(chunks), len(raw)


def verify(simg_in, raw_in):
    # Assert the header fields and that the chunks' block coverage re-expands to
    # exactly the raw image size (block-rounded). Used when simg2img is absent.
    import os
    with open(simg_in, "rb") as f:
        hdr = f.read(FILE_HDR_SZ)
        if len(hdr) != FILE_HDR_SZ:
            raise ValueError("sparse shorter than 28-byte header")
        (magic, major, minor, file_hdr_sz, chunk_hdr_sz, blk_sz,
         total_blks, total_chunks, checksum) = struct.unpack("<IHHHHIIII", hdr)
        assert magic == SPARSE_MAGIC, "bad magic 0x%x" % magic
        assert major == MAJOR_VERSION and minor == MINOR_VERSION, "bad version"
        assert file_hdr_sz == FILE_HDR_SZ, "file_hdr_sz %d" % file_hdr_sz
        assert chunk_hdr_sz == CHUNK_HDR_SZ, "chunk_hdr_sz %d" % chunk_hdr_sz
        assert blk_sz == BLK_SZ, "blk_sz %d" % blk_sz
        assert checksum == 0, "image_checksum %d != 0" % checksum

        covered = 0
        seen = 0
        for c in range(total_chunks):
            ch = f.read(CHUNK_HDR_SZ)
            assert len(ch) == CHUNK_HDR_SZ, "truncated chunk %d" % c
            ctype, reserved, chunk_blks, total_sz = struct.unpack("<HHII", ch)
            data_len = total_sz - CHUNK_HDR_SZ
            if ctype == CHUNK_TYPE_RAW:
                assert data_len == chunk_blks * BLK_SZ, "RAW chunk %d size" % c
                f.seek(data_len, os.SEEK_CUR)
            elif ctype == CHUNK_TYPE_DONT_CARE:
                assert data_len == 0, "DONT_CARE chunk %d has payload" % c
            elif ctype in (CHUNK_TYPE_FILL, CHUNK_TYPE_CRC32):
                f.seek(data_len, os.SEEK_CUR)
            else:
                raise ValueError("unknown chunk type 0x%x at %d" % (ctype, c))
            covered += chunk_blks
            seen += 1
        assert seen == total_chunks, "chunk count %d != header %d" % (seen, total_chunks)
        assert covered == total_blks, "coverage %d != total_blks %d" % (covered, total_blks)

    raw_sz = os.path.getsize(raw_in)
    expanded = total_blks * BLK_SZ
    raw_rounded = ((raw_sz + BLK_SZ - 1) // BLK_SZ) * BLK_SZ
    assert expanded == raw_rounded, \
        "re-expanded %d B != raw size %d B (rounded %d)" % (expanded, raw_sz, raw_rounded)
    sys.stderr.write(
        "[mksparse --verify] OK: %s header valid, %d chunks, %d blocks -> %d B == raw %d B\n"
        % (simg_in, total_chunks, total_blks, expanded, raw_sz))


def main(argv):
    if len(argv) == 4 and argv[1] == "--verify":
        verify(argv[2], argv[3])
        return 0
    if len(argv) != 3:
        sys.stderr.write("usage: mksparse.py <raw_in> <simg_out>\n"
                         "       mksparse.py --verify <simg_in> <raw_in>\n")
        return 2
    raw_in, simg_out = argv[1], argv[2]
    total_blks, total_chunks, raw_len = convert(raw_in, simg_out)
    import os
    simg_len = os.path.getsize(simg_out)
    sys.stderr.write(
        "[mksparse] %s -> %s : %d blocks (%d B raw) in %d chunks, sparse=%d B (%.1f%%)\n"
        % (raw_in, simg_out, total_blks, raw_len, total_chunks, simg_len,
           100.0 * simg_len / raw_len if raw_len else 0.0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
