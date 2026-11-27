#!/tmp/jbresearch/venv/bin/python
"""kextmap.py — per-kext __text size + hash for every LC_FILESET_ENTRY of a kernelcache. TSV: name size hash."""
import sys, struct

FNV_OFF = 1469598103934665603
FNV_PRIME = 1099511628211
MASK64 = 0xffffffffffffffff
LC_FILESET_ENTRY = 0x80000035
LC_SEGMENT_64 = 0x19


def fnv(b):
    h = FNV_OFF
    for byte in b:
        h = ((h ^ byte) * FNV_PRIME) & MASK64
    return h


def filesets(f):
    ncmds = struct.unpack_from('<I', f, 16)[0]
    off = 32
    ents = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == LC_FILESET_ENTRY:
            vmaddr, fileoff = struct.unpack_from('<QQ', f, off + 8)
            eidoff = struct.unpack_from('<I', f, off + 24)[0]
            eid = f[off + eidoff:off + cs].split(b'\0')[0].decode()
            ents.append((vmaddr, fileoff, eid))
        off += cs
    return ents


def text_of(f, fileoff):
    ncmds = struct.unpack_from('<I', f, fileoff + 16)[0]
    off = fileoff + 32
    parts = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', f, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', f, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + s * 80
                sect = f[so:so + 16].rstrip(b'\0').decode(errors='replace')
                size, foff = struct.unpack_from('<QI', f, so + 40)
                if sect.startswith('__text'):
                    parts.append(f[foff:foff + size])
        off += cs
    return parts


if __name__ == '__main__':
    f = open(sys.argv[1], 'rb').read()
    for vmaddr, fileoff, eid in filesets(f):
        parts = text_of(f, fileoff)
        print(f"{eid}\t{sum(len(p) for p in parts)}\t{fnv(b''.join(parts)):016x}")
