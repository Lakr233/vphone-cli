#!/usr/bin/env python3
# REFERENCE IMPLEMENTATION -- no longer called by anything.
#
# Superseded 2026-09-23 by `vphone-cli cfw flip-snapshot`
# (sources/VPhoneCore/VPhoneAPFSSnapshot.swift). The two were compared on a
# synthetic multi-block fixture and produced byte-identical images and
# character-identical output, including the decoy block that must NOT be
# rewritten.
#
# It is kept only until that comparison has been repeated once against a real
# Disk.img, because the blast radius of getting this wrong is a corrupt guest
# filesystem and having the reference to hand beats reading it out of git.
# Delete it then -- it is one of the files D1 counts.
#
# Offline APFS root-snapshot rename for vphone Disk.img (CFW boot-source flip).
#
# Renames the com.apple.os.update-<hash> system snapshot in place so the
# (seal-enforcement-patched) guest kernel can't find the named root snapshot
# and roots the live volume instead -- the same effect as snaputil in the VM,
# done offline on the host: no mount, no fs_snapshot syscall, no kernel CSR
# gate, no host security change. The name is stored in exactly two b-tree
# records (snap_metadata value + snap_name key), normally in one leaf node;
# a same-length rename keeps name_len and single-snapshot b-tree order intact,
# so only the touched block(s)' fletcher64 change.
#
# Usage: apfs_snap_rename.py <Disk.img> [--dry-run] [--new-prefix PREFIX]
#   Auto-detects the com.apple.os.update-* snapshot; only edits records that
#   live in a valid APFS object block (checksum verified), so identical
#   strings baked into on-volume binaries are never touched.
import mmap
import struct
import sys

BS = 4096
OLD_PREFIX = b"com.apple.os.update-"          # 20 bytes
HEXSET = set(b"0123456789abcdefABCDEF")

def cksum(block):
    words = struct.unpack('<%dI' % ((BS - 8) // 4), block[8:BS])
    s1 = s2 = 0
    for w in words:
        s1 = (s1 + w) % 0xFFFFFFFF
        s2 = (s2 + s1) % 0xFFFFFFFF
    c1 = 0xFFFFFFFF - ((s1 + s2) % 0xFFFFFFFF)
    c2 = 0xFFFFFFFF - ((s1 + c1) % 0xFFFFFFFF)
    return c1 | (c2 << 32)

def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    new_prefix = b"orig-fs.disabled.rn-"
    if "--new-prefix" in args:
        i = args.index("--new-prefix")
        new_prefix = args[i+1].encode()
        del args[i:i+2]
    if not args:
        sys.exit("usage: apfs_snap_rename.py <Disk.img> [--dry-run] [--new-prefix PREFIX]")
    img = args[0]
    if len(new_prefix) != len(OLD_PREFIX):
        sys.exit("--new-prefix must be exactly %d bytes" % len(OLD_PREFIX))

    with open(img, 'r+b') as f, mmap.mmap(f.fileno(), 0) as mm:
        # Auto-detect: every "com.apple.os.update-" followed by 64 hex chars, that
        # sits inside a block whose APFS fletcher64 verifies (i.e. a real metadata
        # object, not a string constant inside a Mach-O on the volume).
        hits = {}   # block_off -> list of within-block offsets
        i = 0
        name = None
        while True:
            j = mm.find(OLD_PREFIX, i)
            if j < 0:
                break
            i = j + 1
            hexpart = mm[j+len(OLD_PREFIX):j+len(OLD_PREFIX)+64]
            if len(hexpart) < 64 or any(c not in HEXSET for c in hexpart):
                continue                                  # not a snapshot name
            blk = (j // BS) * BS
            block = bytes(mm[blk:blk+BS])
            if cksum(block) != struct.unpack('<Q', block[0:8])[0]:
                continue                                  # not a valid APFS object block
            if name is None:
                name = mm[j:j+len(OLD_PREFIX)+64].decode(errors="replace")
            hits.setdefault(blk, []).append(j - blk)

        if not hits:
            print("No com.apple.os.update-* root snapshot found. The snapshot may already be renamed.")
            return

        total = sum(len(v) for v in hits.values())
        print("Detected snapshot: %s" % name)
        print("Records: %d in %d block(s): %s" % (total, len(hits), [hex(b) for b in hits]))
        if dry:
            print("Dry run: the prefix would be renamed to %s." % new_prefix.decode())
            return

        for blk, recs in sorted(hits.items()):
            block = bytearray(mm[blk:blk+BS])
            for within in recs:
                assert bytes(block[within:within+len(OLD_PREFIX)]) == OLD_PREFIX
                block[within:within+len(new_prefix)] = new_prefix
            block[0:8] = struct.pack('<Q', cksum(bytes(block)))
            mm[blk:blk+BS] = bytes(block)
            print("Block 0x%x: renamed %d record(s) and fixed the checksum." % (blk, len(recs)))
        mm.flush()
        print("Done. Root snapshot renamed to %s*. The VM will boot the live volume." % new_prefix.decode())

main()
