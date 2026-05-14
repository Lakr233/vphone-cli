"""Standalone Mach-O code-signature page-hash re-attestation.

Parallel to `cfw_dsc_codesign.py` but for standalone Mach-Os instead of
DSC chunks. The technique is the same — recompute the SHA-256 of each
modified page and overwrite the matching slot in `CS_CodeDirectory` —
but the parse path and tail-slot handling differ.

Layout (single-arch arm64e Mach-O, verified on
`iPhone17,3_26.1_23B85_Restore_extracted/usr/libexec/watchdogd`):

    LC_CODE_SIGNATURE (cmd=0x1d) in the Mach-O's own load commands:
        u32 dataoff   — file offset of the embedded CS_SuperBlob
        u32 datasize  — total bytes of the signature

    At `dataoff` there is a CS_SuperBlob (big-endian):
        u32 magic   = 0xFADE0CC0
        u32 length
        u32 count
        CS_BlobIndex blobs[count]:
            u32 type
            u32 offset  (within SuperBlob)

    Every blob whose magic is 0xFADE0C02 is a CodeDirectory. There can
    be more than one (alt-CD with a different hashType for legacy SHA-1
    consumers). We update every CD whose hashType is SHA-256 — anything
    else is left alone and reported, so the caller can decide whether to
    fail.

    A CD covers `[0, codeLimit)` of the Mach-O file. Slot N's hash
    covers bytes `[N * pageSize, min((N+1) * pageSize, codeLimit))`. The
    tail slot is typically short:  `codeLimit - last_slot_start` bytes,
    not a full page. That is the single most likely source of the
    previous standalone-reattest regression — DSC chunks are aligned so
    the tail-slot quirk doesn't surface there.

Page size is read from `pageSizeLog2` in the CD header. On the binaries
we care about it is 12 (4 KiB), not 14 (16 KiB as in DSC chunks).

CDHash side effect (same as DSC case)
-------------------------------------
Rewriting slot hashes mutates the CD blob, which mutates the CD's
SHA-256 (the cdHash). The existing JB kernel patch
`patch_amfi_cdhash_in_trustcache` short-circuits AMFI's trust-cache
lookup so a mutated cdHash isn't rejected at execve. On iPhone17,3 /
iOS 26.1 with `codeSigningMonitor == 2`, TXM accepts the modified-CD
binary on demand-page-in as long as the per-page slot hashes match,
which is exactly what this module guarantees.

Public entrypoint:
    reattest_modified_offsets(filepath, file_offsets, *, dry_run, verbose)
        -> list of diagnostic dicts (one per slot updated)

The caller passes the file offsets of bytes it modified; this module
takes care of mapping each offset to its containing page, deduping,
recomputing the SHA-256 of the page's actual on-disk bytes, and writing
the new hash back into every CD's slot table.

Hash types we know how to recompute:
    SHA-256 (CS_HASHTYPE_SHA256 = 2)

Other types (SHA-1 = 1, SHA-256-truncated = 4, SHA-384 = 3) are
reported but not updated. If a binary needs those it will need
additional code paths.
"""

import hashlib
import os
import struct


# CS constants.
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02

CS_HASHTYPE_SHA1 = 1
CS_HASHTYPE_SHA256 = 2
CS_HASHTYPE_SHA384 = 3
CS_HASHTYPE_SHA256_TRUNCATED = 4

LC_CODE_SIGNATURE = 0x1D

MH_MAGIC_64 = 0xFEEDFACF


def _find_lc_code_signature(data):
    """Return (dataoff, datasize) for the binary's LC_CODE_SIGNATURE, or None."""
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32  # sizeof(mach_header_64)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            return dataoff, datasize
        off += cmdsize
    return None


def _parse_superblob(data, sb_off):
    """Return list of (slot_type, blob_abs_off, blob_magic). None on error."""
    if sb_off + 12 > len(data):
        return None
    sb_magic, sb_length, sb_count = struct.unpack_from(">III", data, sb_off)
    if sb_magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    if sb_count > 256 or sb_off + sb_length > len(data):
        return None
    out = []
    for i in range(sb_count):
        st, bo = struct.unpack_from(">II", data, sb_off + 12 + i * 8)
        blob_abs = sb_off + bo
        if blob_abs + 4 > len(data):
            return None
        bm = struct.unpack_from(">I", data, blob_abs)[0]
        out.append((st, blob_abs, bm))
    return out


def _parse_code_directory(data, cd_off):
    """Parse a CodeDirectory blob. Returns a dict of fields, or None.

    Fields:
        slot_type        — left blank here, filled in by caller from the BlobIndex
        cd_off           — absolute file offset of the CD blob
        cd_length        — length of the CD blob
        hash_offset      — offset within the CD blob to slot[0] (code slot 0)
        hash_size        — bytes per slot
        hash_type        — CS_HASHTYPE_*
        page_size        — 1 << pageSizeLog2
        n_code_slots
        code_limit       — covered byte range of the file
    """
    if cd_off + 44 > len(data):
        return None
    fields = struct.unpack_from(">IIIIIIIII", data, cd_off)
    cd_magic, cd_length, _version, _flags = fields[0], fields[1], fields[2], fields[3]
    if cd_magic != CSMAGIC_CODEDIRECTORY:
        return None
    hash_offset = fields[4]
    _ident_offset = fields[5]
    _n_special = fields[6]
    n_code_slots = fields[7]
    code_limit = fields[8]
    hash_size = data[cd_off + 36]
    hash_type = data[cd_off + 37]
    page_size_log2 = data[cd_off + 39]
    page_size = 1 << page_size_log2 if 0 < page_size_log2 < 24 else 0
    if page_size == 0:
        return None
    if cd_off + cd_length > len(data):
        return None
    if cd_off + hash_offset + n_code_slots * hash_size > len(data):
        return None
    return {
        "cd_off": cd_off,
        "cd_length": cd_length,
        "hash_offset": hash_offset,
        "hash_size": hash_size,
        "hash_type": hash_type,
        "page_size": page_size,
        "page_size_log2": page_size_log2,
        "n_code_slots": n_code_slots,
        "code_limit": code_limit,
    }


def _find_code_directories(data):
    """Find every CS_CodeDirectory in the binary's LC_CODE_SIGNATURE blob.

    Returns a list of dicts (one per CD), each with the fields from
    `_parse_code_directory` plus `slot_type` from the SuperBlob's
    BlobIndex.
    """
    cs = _find_lc_code_signature(data)
    if cs is None:
        return None
    cs_off, _cs_size = cs
    sb = _parse_superblob(data, cs_off)
    if sb is None:
        return None
    cds = []
    for slot_type, blob_abs, blob_magic in sb:
        if blob_magic != CSMAGIC_CODEDIRECTORY:
            continue
        cd = _parse_code_directory(data, blob_abs)
        if cd is None:
            continue
        cd["slot_type"] = slot_type
        cds.append(cd)
    return cds


def _page_bounds(file_off, page_size, code_limit):
    """Return (page_index, page_start, page_end_exclusive) for the page
    that contains file_off. page_end_exclusive is clamped to code_limit
    so the tail slot covers the actual signed byte range, not a full
    page beyond the end of the CD-covered region.

    Returns None if file_off is past code_limit (not covered by CD).
    """
    if file_off >= code_limit:
        return None
    page_index = file_off // page_size
    page_start = page_index * page_size
    page_end = min(page_start + page_size, code_limit)
    return page_index, page_start, page_end


def reattest_modified_offsets(
    filepath, file_offsets, *, dry_run=False, verbose=True
):
    """Recompute slot hashes for every page touched by `file_offsets`.

    `file_offsets`  iterable of byte offsets within the Mach-O file
                    that the caller has just modified. They get
                    deduplicated to a set of (cd, page_index) pairs.
    `dry_run`       if True, log only, do not write.
    `verbose`       if True, print per-slot progress.

    Returns a list of diagnostic dicts:
        {cd_off, slot_type, page_index, page_start, page_end,
         hash_offset_in_file, before, after}

    Raises ValueError on a malformed signature blob — that's a hard
    error for any caller (the binary was not what we expected).
    """
    if not file_offsets:
        if verbose:
            print(f"  [.] re-attest: no offsets given for {filepath}")
        return []

    with open(filepath, "rb") as f:
        data = f.read()

    cds = _find_code_directories(data)
    if cds is None:
        raise ValueError(
            f"{filepath}: no LC_CODE_SIGNATURE / CS_CodeDirectory found"
        )
    if not cds:
        raise ValueError(
            f"{filepath}: LC_CODE_SIGNATURE present but no CodeDirectory blobs"
        )

    if verbose:
        kinds = []
        for cd in cds:
            kinds.append(
                f"slot_type=0x{cd['slot_type']:x} hashType={cd['hash_type']} "
                f"pageSize={cd['page_size']} nSlots={cd['n_code_slots']} "
                f"codeLimit=0x{cd['code_limit']:x}"
            )
        print(f"  [.] re-attest {filepath}: {len(cds)} CD(s): " + "; ".join(kinds))

    # Build (cd_index, page_index) -> (page_start, page_end) set.
    # Different CDs may have different page sizes in theory; we keep
    # them separate.
    work = {}  # (cd_index, page_index) -> (page_start, page_end)
    skipped_non_sha256 = 0
    for cd_i, cd in enumerate(cds):
        if cd["hash_type"] != CS_HASHTYPE_SHA256:
            skipped_non_sha256 += 1
            continue
        for foff in file_offsets:
            pb = _page_bounds(foff, cd["page_size"], cd["code_limit"])
            if pb is None:
                if verbose:
                    print(
                        f"      [-] re-attest: file off 0x{foff:X} past codeLimit "
                        f"0x{cd['code_limit']:X} (cd_index={cd_i}) — skipping"
                    )
                continue
            page_index, page_start, page_end = pb
            if page_index >= cd["n_code_slots"]:
                if verbose:
                    print(
                        f"      [-] re-attest: page {page_index} >= "
                        f"nCodeSlots {cd['n_code_slots']} (cd_index={cd_i}) — skipping"
                    )
                continue
            work[(cd_i, page_index)] = (page_start, page_end)

    if skipped_non_sha256 and verbose:
        print(
            f"      [-] re-attest: skipped {skipped_non_sha256} non-SHA256 "
            f"CD(s) (hashType != 2). If a legacy SHA-1 alt-CD exists for "
            f"this binary it is NOT being recomputed."
        )

    if not work:
        if verbose:
            print(f"  [.] re-attest: no eligible slots for {filepath}")
        return []

    diagnostics = []
    mode = "rb" if dry_run else "r+b"
    with open(filepath, mode) as f:
        for (cd_i, page_index), (page_start, page_end) in sorted(work.items()):
            cd = cds[cd_i]
            slot_off = (
                cd["cd_off"] + cd["hash_offset"] + page_index * cd["hash_size"]
            )
            page_bytes = data[page_start:page_end]
            new_hash = hashlib.sha256(page_bytes).digest()
            old_hash = data[slot_off : slot_off + cd["hash_size"]]

            if old_hash == new_hash:
                if verbose:
                    print(
                        f"      [.] re-attest: cd_index={cd_i} slot {page_index} "
                        f"already matches ({page_end - page_start} bytes) — no-op"
                    )
                continue

            if not dry_run:
                f.seek(slot_off)
                f.write(new_hash)

            if verbose:
                action = "would write" if dry_run else "wrote"
                tail_note = ""
                if page_end - page_start != cd["page_size"]:
                    tail_note = f" [tail, {page_end - page_start}B]"
                print(
                    f"      [+] re-attest: {action} cd_index={cd_i} "
                    f"slot {page_index}{tail_note}  "
                    f"({old_hash.hex()[:8]}.. -> {new_hash.hex()[:8]}..)"
                )
            diagnostics.append(
                {
                    "cd_off": cd["cd_off"],
                    "slot_type": cd["slot_type"],
                    "page_index": page_index,
                    "page_start": page_start,
                    "page_end": page_end,
                    "hash_offset_in_file": slot_off,
                    "before": old_hash.hex(),
                    "after": new_hash.hex(),
                }
            )

    return diagnostics
