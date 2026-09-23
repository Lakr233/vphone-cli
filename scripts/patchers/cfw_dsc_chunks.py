"""dyld shared cache (split / chunked) byte-level helper.

The iOS 26 SystemOS Cryptex ships the DSC as multiple files:

    /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
    /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.01
    /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.02
    ...

The first file (no suffix) holds the cache header; suffixed files
(`.NN`) hold subcache regions. Together they map a contiguous virtual
address space.

This module gives us:

    chunks = DSCChunks(chunks_dir)
    chunks.bytes_at_vma(vma, length) -> bytes
    chunks.find_chunk_for_vma(vma)   -> (chunk_path, file_offset)
    chunks.write_at_vma(vma, data)   -> None    # persists to chunk on disk

It does *not* extract dylibs. It treats the DSC as a flat virtual
address space and gives byte-level access. That's the minimum we need
to apply 4-byte instruction patches at known vmaddrs.

The dyld_cache_header layout we use is intentionally minimal:
    char     magic[16];
    uint32_t mappingOffset;
    uint32_t mappingCount;
    ...
    uint64_t sharedRegionStart;     (offset 0x60 in modern caches)
    uint64_t sharedRegionSize;
    ...

The dyld_cache_mapping_info entries (mappingCount of them) each look:
    uint64_t address;
    uint64_t size;
    uint64_t fileOffset;
    uint32_t maxProt;
    uint32_t initProt;

For chunked caches (.NN files), each chunk has its own header with its
own mappings; the mappings address ranges are non-overlapping across
chunks.

Reference: dyld project, dyld_cache_format.h.
"""

import os
import struct
import re

try:
    from .cfw_asm import _cs
    from . import cfw_records as records
except ImportError:  # direct self-test / standalone execution
    from cfw_asm import _cs
    import cfw_records as records


def _enumerate_chunks(chunks_dir):
    """Return list of chunk file paths in numeric order; the unsuffixed file
    first, then .01, .02, ... `.symbols` is excluded (it doesn't map code).
    """
    names = []
    for name in os.listdir(chunks_dir):
        if not name.startswith("dyld_shared_cache_arm64e"):
            continue
        if name.endswith(".symbols") or name.endswith(".map"):
            continue
        names.append(name)

    def sort_key(n):
        # base file (no suffix) first, then .01, .02, ...
        m = re.match(r"^dyld_shared_cache_arm64e(?:\.(\d+))?$", n)
        if m:
            return (0, int(m.group(1)) if m.group(1) else -1)
        return (1, n)

    names.sort(key=sort_key)
    return [os.path.join(chunks_dir, n) for n in names]


def _parse_chunk_mappings(path):
    """Return list of dicts {addr, size, file_off, max_prot, init_prot}
    for one chunk file.

    Only the standard dyld_cache_mapping_info entries are used. Slide-info
    mappings (`mappingWithSlideOffset`) are ignored — for our purposes we
    only care about which virtual address comes from which file offset,
    and the standard mappings cover that.

    `init_prot` is the VM_PROT mask: VM_PROT_READ=1, VM_PROT_WRITE=2,
    VM_PROT_EXECUTE=4.
    """
    with open(path, "rb") as f:
        head = f.read(0x100)
    magic = head[:16].rstrip(b"\x00")
    # Modern arm64e caches start with "dyld_v1   arm64e"
    if not magic.startswith(b"dyld"):
        return []

    mapping_off = struct.unpack_from("<I", head, 16)[0]
    mapping_cnt = struct.unpack_from("<I", head, 20)[0]
    if mapping_cnt > 64 or mapping_off > 0x10000:
        # sanity bounds
        return []

    with open(path, "rb") as f:
        f.seek(mapping_off)
        raw = f.read(mapping_cnt * 32)

    out = []
    for i in range(mapping_cnt):
        off = i * 32
        addr, size, file_off, max_prot, init_prot = \
            struct.unpack_from("<QQQII", raw, off)
        out.append({
            "addr": addr, "size": size, "file_off": file_off,
            "max_prot": max_prot, "init_prot": init_prot,
        })
    return out


def resolve_local_symbol(chunks_dir, name):
    """Resolve a symbol (including an ObjC method symbol) to its vmaddr via the
    DSC's own `.symbols` local-symbol table (in-image; no repo-exported dumps).
    ipsw `symaddr -a` times out on this cache, so parse the table directly."""
    sym = os.path.join(chunks_dir, "dyld_shared_cache_arm64e.symbols")
    with open(sym, "rb") as f:
        hdr = f.read(0x100)
        if hdr[:15] != b"dyld_v1  arm64e":
            raise RuntimeError(f"unexpected .symbols magic in {sym}")
        local_off = struct.unpack_from("<Q", hdr, 72)[0]
        f.seek(local_off)
        nlist_off, nlist_cnt, str_off, str_sz, _eo, _ec = struct.unpack("<IIIIII", f.read(24))
        f.seek(local_off + str_off)
        strings = f.read(str_sz)
        f.seek(local_off + nlist_off)
        nl = f.read(nlist_cnt * 16)
    want = name.encode()
    for i in range(nlist_cnt):
        n_strx, _t, _s, _d, n_value = struct.unpack_from("<IBBHQ", nl, i * 16)
        if n_strx >= len(strings):
            continue
        end = strings.find(b"\x00", n_strx)
        if strings[n_strx:end] == want:
            return n_value
    raise RuntimeError(f"could not resolve {name!r} in .symbols")


def _disasm_function(chunks, vma, max_insns):
    """Disassemble from `vma` up to the first ret/retab (function end) or
    `max_insns`, whichever comes first. `chunks` is a DSCChunks."""
    buf = chunks.bytes_at_vma(vma, max_insns * 4)
    insns = []
    for insn in _cs.disasm(buf, vma):
        insns.append(insn)
        if insn.mnemonic in ("ret", "retab"):
            break
    return insns


class DSCChunks:
    """Lazy random-access byte view over a chunked dyld shared cache."""

    def __init__(self, chunks_dir):
        self.chunks_dir = chunks_dir
        self._chunk_paths = _enumerate_chunks(chunks_dir)
        if not self._chunk_paths:
            raise FileNotFoundError(
                f"No dyld_shared_cache_arm64e* chunks found under {chunks_dir!r}"
            )

        # Build (addr_start, addr_end, file_off, init_prot, chunk_path) ranges.
        ranges = []
        for cp in self._chunk_paths:
            for m in _parse_chunk_mappings(cp):
                if m["size"] == 0:
                    continue
                ranges.append(
                    (
                        m["addr"],
                        m["addr"] + m["size"],
                        m["file_off"],
                        m["init_prot"],
                        cp,
                    )
                )
        if not ranges:
            raise RuntimeError(
                f"No DSC mappings parsed under {chunks_dir!r} — "
                f"chunks present but headers unrecognised"
            )

        # Sort by addr_start for binary-search later.
        ranges.sort(key=lambda r: r[0])
        self._ranges = ranges

    def __repr__(self):
        return (
            f"DSCChunks({self.chunks_dir!r}, "
            f"{len(self._chunk_paths)} chunk(s), "
            f"{len(self._ranges)} mapping(s), "
            f"vm 0x{self._ranges[0][0]:X}..0x{self._ranges[-1][1]:X})"
        )

    def find_chunk_for_vma(self, vma):
        """Return (chunk_path, file_offset) for `vma`, or None if unmapped."""
        # Linear scan is fine; mapping count is < ~80.
        for addr_start, addr_end, file_off, _init_prot, cp in self._ranges:
            if addr_start <= vma < addr_end:
                return (cp, file_off + (vma - addr_start))
        return None

    def bytes_at_vma(self, vma, length):
        """Read `length` bytes starting at `vma`. Must be contained in one
        mapping (we don't stitch across mappings)."""
        loc = self.find_chunk_for_vma(vma)
        if loc is None:
            raise KeyError(f"vma 0x{vma:X} is not mapped by any chunk")
        cp, foff = loc
        with open(cp, "rb") as f:
            f.seek(foff)
            data = f.read(length)
        if len(data) != length:
            raise IOError(
                f"short read at vma 0x{vma:X} ({len(data)} of {length})"
            )
        return data

    def write_at_vma(self, vma, data):
        """Persist `data` bytes at `vma` to the right chunk file. The
        target span must lie within a single mapping."""
        loc = self.find_chunk_for_vma(vma)
        if loc is None:
            raise KeyError(f"vma 0x{vma:X} is not mapped by any chunk")
        # Verify the entire span is in this mapping.
        end_loc = self.find_chunk_for_vma(vma + len(data) - 1)
        if end_loc is None or end_loc[0] != loc[0]:
            raise ValueError(
                f"write at vma 0x{vma:X} length {len(data)} "
                f"crosses a chunk boundary — refusing"
            )
        cp, foff = loc
        # Every DSC patcher funnels through here, so this is the one place the
        # reference capture has to read the original bytes — and it has to read
        # them before the write, not reconstruct them after.
        original = None
        if records.enabled():
            records.note_dsc_page(cp, foff)
            with open(cp, "rb") as f:
                f.seek(foff)
                original = f.read(len(data))
        with open(cp, "r+b") as f:
            f.seek(foff)
            f.write(data)
        if original is not None:
            records.record_span(os.path.basename(cp), foff, original, data,
                                virtual_address=vma, source_file=cp)

    # ---- additional helpers used by the DSC-native canonical-site finder ----

    VM_PROT_EXECUTE = 4

    def mappings(self):
        """Return [(vmaddr_start, vmaddr_end, file_offset, init_prot, chunk_path)]."""
        return list(self._ranges)

    def find_string_vmas(self, needle):
        """Return all vmaddrs where `needle` (bytes) appears within a single
        mapping, anchored either at the mapping start or after a NUL byte.

        Restricted to executable (RX) mappings — `__TEXT` segments where
        `__TEXT,__cstring` lives. This skips the giant LINKEDIT and
        __DATA/__DATA_CONST mappings entirely.
        """
        out = []
        for addr_start, addr_end, file_off, init_prot, cp in self._ranges:
            if not (init_prot & self.VM_PROT_EXECUTE):
                continue
            size = addr_end - addr_start
            with open(cp, "rb") as f:
                f.seek(file_off)
                buf = f.read(size)
            i = 0
            while True:
                p = buf.find(needle, i)
                if p < 0:
                    break
                if p == 0 or buf[p - 1] == 0:
                    out.append(addr_start + p)
                i = p + 1
        return out

    def read_at_vma(self, vma, length, *, allow_short=False):
        """Read `length` bytes starting at `vma`, contained in a single
        mapping. With `allow_short=True`, returns whatever is available
        within the containing mapping instead of raising."""
        for addr_start, addr_end, file_off, _init_prot, cp in self._ranges:
            if addr_start <= vma < addr_end:
                avail = addr_end - vma
                want = length if avail >= length else (avail if allow_short else 0)
                if want == 0:
                    raise IOError(
                        f"read at vma 0x{vma:X} len {length} would cross "
                        f"a chunk boundary"
                    )
                with open(cp, "rb") as f:
                    f.seek(file_off + (vma - addr_start))
                    data = f.read(want)
                return data
        raise KeyError(f"vma 0x{vma:X} is not mapped by any chunk")

    _MH_MAGIC_64_LE = b"\xcf\xfa\xed\xfe"

    def find_macho_header_before(self, vma, *, max_walk=64 * 1024 * 1024):
        """Walk backwards from `vma` looking for a Mach-O 64 header
        (magic 0xfeedfacf) at a page boundary. Returns the magic's
        vmaddr, or None if not found within `max_walk` bytes inside the
        same mapping.

        Mach-O headers in the DSC are placed at page-aligned vmaddrs at
        the start of each dylib's __TEXT segment, and an arm64e iOS
        dylib's header is in the same mapping as its __text section, so
        we only have to search within the containing mapping.

        Implementation: read the relevant bytes from disk once and use
        `bytes.rfind` to locate the magic, then accept only page-aligned
        hits.  Searching ~36 MiB takes <50 ms in pure Python.
        """
        for addr_start, addr_end, file_off, _init_prot, cp in self._ranges:
            if not (addr_start <= vma < addr_end):
                continue
            local_off = vma - addr_start
            scan_len = min(local_off, max_walk)
            scan_start = local_off - scan_len
            with open(cp, "rb") as f:
                f.seek(file_off + scan_start)
                buf = f.read(scan_len + 4)  # +4 so a hit at end is captured
            i = len(buf)
            while True:
                found = buf.rfind(self._MH_MAGIC_64_LE, 0, i)
                if found < 0:
                    return None
                candidate_vma = addr_start + scan_start + found
                if (candidate_vma & 0xFFF) == 0:
                    return candidate_vma
                # Keep searching backwards.
                i = found
            # unreachable
        return None

    def read_install_name_at(self, header_vma):
        """Given the vmaddr of a Mach-O 64 header in the DSC, return the
        dylib's install name (LC_ID_DYLIB), or None if the file isn't a
        dylib or the LC isn't present.
        """
        # Read the first 64KB of LCs (more than enough).
        try:
            head = self.read_at_vma(header_vma, 64 * 1024, allow_short=True)
        except (KeyError, IOError):
            return None
        if struct.unpack_from("<I", head, 0)[0] != 0xFEEDFACF:
            return None
        ncmds = struct.unpack_from("<I", head, 16)[0]
        sizeofcmds = struct.unpack_from("<I", head, 20)[0]
        # Sanity-bound the LC walk.
        if ncmds > 4096 or sizeofcmds > 64 * 1024:
            return None
        o = 32
        for _ in range(ncmds):
            if o + 8 > len(head):
                return None
            cmd, cmdsize = struct.unpack_from("<II", head, o)
            if cmdsize < 8 or cmdsize > 64 * 1024:
                return None
            if cmd == 0xD:  # LC_ID_DYLIB
                # struct dylib_command { cmd, cmdsize, dylib { name(uint32 offset),
                # timestamp, current_version, compatibility_version } }
                name_off_in_cmd = struct.unpack_from("<I", head, o + 8)[0]
                name_pos = o + name_off_in_cmd
                if name_pos >= len(head) or name_pos >= o + cmdsize:
                    return None
                end = head.find(b"\x00", name_pos, o + cmdsize)
                if end < 0:
                    return None
                try:
                    return head[name_pos:end].decode("utf-8")
                except UnicodeDecodeError:
                    return head[name_pos:end].decode("latin-1")
            o += cmdsize
            if o > sizeofcmds + 32:
                return None
        return None
