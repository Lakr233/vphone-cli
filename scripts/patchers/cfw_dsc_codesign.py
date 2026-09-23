"""DSC code-signature page-hash re-attestation.

Background
----------
On iPhone17,3 / iOS 26.1 with TXM (`codeSigningMonitor == 2`) enabled,
the kernel defers per-page hash validation to TXM (see source comments
in `research/reference/xnu/osfmk/vm/vm_fault.c:2763-2780`). TXM has
the original slot hashes baked in via the registered DSC signature, so
any byte-mangle inside an executable mapping causes
`KERN_PROTECTION_FAILURE` / `CODESIGNING / Invalid Page` SIGKILL on
the first demand-page-in of the affected 16 KiB page. (An earlier
XNU-side `_cs_validate_page` short-circuit kernel patch was attempted
and shipped, then removed — it never fires on this hardware because
the CSM-defer gate in `vm_fault_cs_check_violation` runs first.)

To make a byte-mangled DSC dylib executable again, we recompute the
SHA-256 slot hash for the 16 KiB page that contains the modification
and overwrite the matching entry in the chunk's `CS_CodeDirectory`.

DSC code-signature layout (verified empirically on
`iPhone17,3_26.1_23B85` chunked DSC):

    Each chunk file has a `dyld_cache_header`:
        u64 codeSignatureOffset  @ 0x28 (chunk-file relative)
        u64 codeSignatureSize    @ 0x30

    At `codeSignatureOffset` there's a `CS_SuperBlob` (big-endian):
        u32 magic   = 0xFADE0CC0
        u32 length
        u32 count
        CS_BlobIndex blobs[count]:
            u32 type
            u32 offset  (within SuperBlob)

    The CSSLOT_CODEDIRECTORY entry (type==0) points at a
    `CS_CodeDirectory` blob (also big-endian):
        u32 magic   = 0xFADE0C02
        u32 length
        u32 version
        u32 flags
        u32 hashOffset      (within blob — to slot[0])
        u32 identOffset
        u32 nSpecialSlots
        u32 nCodeSlots
        u32 codeLimit       (chunk-file byte range covered)
        u8  hashSize        (32 for SHA-256)
        u8  hashType        (2 for SHA-256)
        u8  platform
        u8  pageSize        (log2 — 14 == 16 KiB)
        u32 spare2
        ... (more in later versions)

    Slot N stores SHA-256 of chunk bytes [N*pageSize, (N+1)*pageSize)
    and lives at chunk-file offset:
        codeSignatureOffset + cd_offset_in_superblob
            + hashOffset + N * hashSize

DSC dylibs do NOT carry their own LC_CODE_SIGNATURE — only the
chunk-level signature applies. Page indexing is against the chunk
file offset, not the dylib's __TEXT offset.

CDHash side effect (empirically benign)
---------------------------------------
Modifying slot hashes changes the CodeDirectory's contents, which
changes its CDHash (SHA-256 of the CD blob). The existing JB kernel
patch `patch_amfi_cdhash_in_trustcache` bypasses AMFI's per-image
CDHash trust-cache lookup, and TXM accepts the modified-CDHash DSC
at cache-load time on iPhone17,3 / iOS 26.1 (verified: device boots
with re-attested chunks). If a future build introduces a stricter
CDHash check at DSC mount, the next step would be a TXM-side bypass
at cache load — at the time this module was written that wasn't
needed.

"""

import hashlib
import os
import struct

try:
    from . import cfw_records as records
except ImportError:  # direct self-test / standalone execution
    import cfw_records as records


# CS constants.
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0

CS_HASHTYPE_SHA256 = 2


def _read_chunk_cd_blob(chunk_path):
    """Locate the chunk's CS_CodeDirectory.

    Returns a dict with the fields we need to write back slot hashes:
        cd_file_off       (chunk-file offset of the CD blob)
        cd_length         (total length of the CD blob in bytes)
        hash_offset       (offset within the CD blob to slot[0])
        hash_size         (bytes per slot — 32 for SHA-256)
        n_code_slots      (number of slots)
        code_limit        (chunk byte range covered)
        page_size         (1 << pageSize_log2 — typically 16384)

    Returns None if the chunk file isn't recognised (header magic
    mismatch, no CodeDirectory in SuperBlob, etc.).
    """
    with open(chunk_path, "rb") as f:
        head = f.read(0x100)
    if not head.startswith(b"dyld_"):
        return None

    # codeSignatureOffset at 0x28, codeSignatureSize at 0x30 (both u64 LE).
    cs_off, cs_size = struct.unpack_from("<QQ", head, 0x28)
    if cs_off == 0 or cs_size == 0:
        return None

    # SuperBlob (big-endian).
    with open(chunk_path, "rb") as f:
        f.seek(cs_off)
        sb_head = f.read(12)
    if len(sb_head) != 12:
        return None
    sb_magic, sb_length, sb_count = struct.unpack(">III", sb_head)
    if sb_magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    if sb_length > cs_size or sb_count > 256:
        return None

    # Read the BlobIndex array.
    with open(chunk_path, "rb") as f:
        f.seek(cs_off + 12)
        idx_bytes = f.read(sb_count * 8)
    if len(idx_bytes) != sb_count * 8:
        return None

    cd_off_in_sb = None
    for i in range(sb_count):
        slot_type, slot_off = struct.unpack_from(">II", idx_bytes, i * 8)
        if slot_type == CSSLOT_CODEDIRECTORY:
            cd_off_in_sb = slot_off
            break
    if cd_off_in_sb is None:
        return None

    cd_file_off = cs_off + cd_off_in_sb

    # CD blob header (big-endian).
    with open(chunk_path, "rb") as f:
        f.seek(cd_file_off)
        cd_head = f.read(44)
    if len(cd_head) != 44:
        return None
    cd_magic, cd_length, _version, _flags = struct.unpack_from(">IIII", cd_head, 0)
    if cd_magic != CSMAGIC_CODEDIRECTORY:
        return None
    hash_offset, _ident_offset, _n_special, n_code_slots, code_limit = \
        struct.unpack_from(">IIIII", cd_head, 16)
    hash_size = cd_head[36]
    hash_type = cd_head[37]
    page_size_log2 = cd_head[39]
    if hash_type != CS_HASHTYPE_SHA256 or hash_size != 32:
        # We only know how to recompute SHA-256 slots. Other hash types
        # (SHA-1, SHA-256-truncated) would need additional code paths.
        return None
    page_size = 1 << page_size_log2
    if page_size == 0 or page_size > (1 << 20):
        return None

    return {
        "cd_file_off": cd_file_off,
        "cd_length": cd_length,
        "hash_offset": hash_offset,
        "hash_size": hash_size,
        "n_code_slots": n_code_slots,
        "code_limit": code_limit,
        "page_size": page_size,
    }


def reattest_modified_pages(chunks, modified_vmas, *, dry_run=False, verbose=True):
    """Recompute and write SHA-256 slot hashes for every 16 KiB page
    that contains a `modified_vmas` entry.

    `chunks`        a DSCChunks instance.
    `modified_vmas` iterable of vmaddrs we wrote to. Each is reduced
                    to its containing chunk + page; duplicate pages
                    are coalesced.
    `dry_run`       if True, log only, do not write.

    Returns a list of dicts (one per page recomputed) for diagnostics:
        {chunk_path, page_index, chunk_off, sha256_before, sha256_after}
    """
    # Group vmas by chunk → set of page indices to recompute.
    chunks_pages = {}      # chunk_path → set(page_index)
    chunk_meta = {}        # chunk_path → cd metadata (lazy-loaded)

    for vma in modified_vmas:
        loc = chunks.find_chunk_for_vma(vma)
        if loc is None:
            if verbose:
                print(f"      [-] re-attest: vma 0x{vma:X} not mapped in any chunk")
            continue
        cp, foff = loc
        meta = chunk_meta.get(cp)
        if meta is None:
            meta = _read_chunk_cd_blob(cp)
            if meta is None:
                if verbose:
                    print(f"      [-] re-attest: chunk {os.path.basename(cp)!r} "
                          f"has no recognised CS_SuperBlob/CD — skipping")
                # Cache the None so we don't re-probe.
                chunk_meta[cp] = False
                continue
            chunk_meta[cp] = meta
        elif meta is False:
            continue
        page_size = meta["page_size"]
        page_index = foff // page_size
        if page_index >= meta["n_code_slots"]:
            if verbose:
                print(f"      [-] re-attest: vma 0x{vma:X} -> page {page_index} "
                      f"is past nCodeSlots ({meta['n_code_slots']}) in "
                      f"{os.path.basename(cp)} — skipping")
            continue
        if (page_index + 1) * page_size > meta["code_limit"]:
            if verbose:
                print(f"      [-] re-attest: vma 0x{vma:X} -> page {page_index} "
                      f"overruns codeLimit (0x{meta['code_limit']:X}) in "
                      f"{os.path.basename(cp)} — skipping")
            continue
        chunks_pages.setdefault(cp, set()).add(page_index)

    if not chunks_pages:
        if verbose:
            print(f"      [.] re-attest: no eligible pages")
        return []

    diagnostics = []
    total = 0
    for cp, pages in chunks_pages.items():
        meta = chunk_meta[cp]
        cd_file_off = meta["cd_file_off"]
        hash_offset = meta["hash_offset"]
        hash_size = meta["hash_size"]
        page_size = meta["page_size"]

        # Open once per chunk for read/write.
        mode = "rb" if dry_run else "r+b"
        with open(cp, mode) as f:
            for page_index in sorted(pages):
                page_off = page_index * page_size
                slot_off = cd_file_off + hash_offset + page_index * hash_size

                f.seek(page_off)
                page_data = f.read(page_size)
                if len(page_data) != page_size:
                    if verbose:
                        print(f"      [-] re-attest: short read at "
                              f"page {page_index} of {os.path.basename(cp)} "
                              f"(got {len(page_data)} of {page_size})")
                    continue
                new_hash = hashlib.sha256(page_data).digest()

                f.seek(slot_off)
                old_hash = f.read(hash_size)

                if old_hash == new_hash:
                    if verbose:
                        print(f"      [.] re-attest: page {page_index} of "
                              f"{os.path.basename(cp)} slot already matches "
                              f"(no-op)")
                    continue

                if not dry_run:
                    f.seek(slot_off)
                    f.write(new_hash)

                if verbose:
                    action = "would write" if dry_run else "wrote"
                    print(f"      [+] re-attest: {action} slot {page_index} of "
                          f"{os.path.basename(cp)}  "
                          f"({old_hash.hex()[:8]}.. -> {new_hash.hex()[:8]}..)")
                diagnostics.append({
                    "chunk_path": cp,
                    "page_index": page_index,
                    "chunk_off": page_off,
                    "slot_off": slot_off,
                    "sha256_before": old_hash.hex(),
                    "sha256_after": new_hash.hex(),
                })
                total += 1

    if verbose:
        action = "would update" if dry_run else "updated"
        print(f"  [+] re-attest: {action} {total} slot hash(es) across "
              f"{len(chunks_pages)} chunk(s)")
    if not dry_run and records.enabled():
        # P1.1's gate is that the Swift slot hashes come out byte-identical to
        # these, so the re-attestation belongs in the snapshot as much as the
        # instruction patches do.
        for d in diagnostics:
            records.record(
                f"codesign.dsc.slot{d['page_index']}",
                os.path.basename(d["chunk_path"]),
                d["slot_off"],
                bytes.fromhex(d["sha256_before"]),
                bytes.fromhex(d["sha256_after"]),
                description=(
                    f"DSC CodeDirectory slot {d['page_index']} "
                    f"(page at 0x{d['chunk_off']:X}) re-attested"
                ),
                source_file=d["chunk_path"],
            )
    return diagnostics
