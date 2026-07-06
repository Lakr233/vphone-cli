#!/usr/bin/env python3
"""cfw_patch_post_restore_dt.py — post-restore DT identity rewrite.

Applies the three restore-unsafe DT property edits that broke earlier
attempts when applied at fw_patch time:

    root/model        "iPhone99,11"            -> "iPhone17,3"
    root/target-type  "VPHONE600"              -> "D47"
    root/compatible   ["VPHONE600AP", "*", "AppleVirtualPlatformARM"]
                                               -> ["D47AP", "VPHONE600AP",
                                                   "AppleVirtualPlatformARM"]

These edits are restore-time-fatal — `restored_external` / iBoot's restore
mode cross-checks DT root `model` / `target-type` against the
BuildManifest's signed identity and rejects the device on mismatch — but
they are NOT boot-time-fatal. After restore completes, the existing iBSS /
iBEC / LLB image4_validate_property_callback bypass patches accept any
IM4P contents, so re-patching the DT offline (on the host-mounted restored
filesystem) before the device boots into the rootfs is safe.

The `compatible` rewrite is a reorder, not a replacement: VPHONE600AP
stays in the list (now as the second entry) so IOKit's platform-expert
binding to AppleVMApple1IO still works. The first entry, which userland
queries for `hw.model`, becomes D47AP — flipping the visible board
identifier without breaking kernel kext binding.

Layout summary:

  before:  "VPHONE600AP\\0iPhone99,11\\0AppleVirtualPlatformARM\\0"        (48B)
        OR "VPHONE600AP\\0iPhone17,3\\0AppleVirtualPlatformARM\\0\\0"      (48B, post-Tier1b)
  after:   "D47AP\\0VPHONE600AP\\0AppleVirtualPlatformARM\\0" + 6 NUL pad  (48B)

This script runs on the host. The install pipeline copies the
devicetree.img4 out of the host-mounted `/mnt5/<boot-hash>/usr/standalone/firmware/`,
this script edits it in place, and the pipeline copies it back to the same
path. The boot-manifest-hash directory is the same one discovered by
`get_boot_manifest_hash` in `cfw_install_jb.sh`.

Dependencies:
    pip install pyimg4
    (already in the project's requirements.txt; uses pyimg4's LZFSE
    round-trip + IMG4/IM4P/IM4M repack.)

Idempotent: a re-run on an already-patched img4 detects "no change" and
exits without rewriting.
"""

import sys

import pyimg4


# ──────────────────────────────────────────────────────────────────────
# Device Tree binary format parser/serializer (mirrors
# DeviceTreePatcher.swift's behavior in Swift).
#
# Per-node layout:
#   u32 nProps
#   u32 nChildren
#   for each property:
#       char[32]  name (NUL-padded)
#       u16       length (high bit = "placeholder" flag, mask 0x7FFF)
#       u16       flags
#       u8[len]   value
#       padding to 4-byte boundary
#   for each child:
#       (recursive node)
# ──────────────────────────────────────────────────────────────────────


def _align4(n: int) -> int:
    return (n + 3) & ~3


class DTProperty:
    __slots__ = ("name", "length", "flags", "value", "value_offset")

    def __init__(self, name, length, flags, value, value_offset):
        self.name = name
        self.length = length
        self.flags = flags
        self.value = value
        self.value_offset = value_offset


class DTNode:
    __slots__ = ("properties", "children")

    def __init__(self):
        self.properties = []
        self.children = []


def _parse_node(blob: bytes, offset: int):
    if offset + 8 > len(blob):
        raise ValueError(f"DT truncated at offset 0x{offset:X}")
    n_props = int.from_bytes(blob[offset : offset + 4], "little")
    n_children = int.from_bytes(blob[offset + 4 : offset + 8], "little")
    pos = offset + 8
    node = DTNode()
    for _ in range(n_props):
        if pos + 36 > len(blob):
            raise ValueError(f"DT property header truncated at 0x{pos:X}")
        name = blob[pos : pos + 32].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        # Length field's top bit is the "placeholder" / out-of-line flag in some
        # XNU branches; mask it for the actual size.
        raw_len = int.from_bytes(blob[pos + 32 : pos + 34], "little")
        masked_len = raw_len & 0x7FFF
        flags = int.from_bytes(blob[pos + 34 : pos + 36], "little")
        value_off = pos + 36
        value = blob[value_off : value_off + masked_len]
        node.properties.append(DTProperty(name, masked_len, flags, value, value_off))
        pos = value_off + _align4(masked_len)
    for _ in range(n_children):
        child, pos = _parse_node(blob, pos)
        node.children.append(child)
    return node, pos


def _serialize_node(node: DTNode) -> bytes:
    out = bytearray()
    out += len(node.properties).to_bytes(4, "little")
    out += len(node.children).to_bytes(4, "little")
    for prop in node.properties:
        name = prop.name.encode("utf-8")
        if len(name) >= 32:
            name = name[:31]
        out += name + b"\x00" * (32 - len(name))
        out += prop.length.to_bytes(2, "little")
        out += prop.flags.to_bytes(2, "little")
        out += prop.value
        pad = _align4(prop.length) - prop.length
        if pad:
            out += b"\x00" * pad
    for child in node.children:
        out += _serialize_node(child)
    return bytes(out)


def _get_node_name(node: DTNode) -> str:
    for p in node.properties:
        if p.name == "name":
            return p.value.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    return ""


def _find_property(node: DTNode, name: str) -> DTProperty:
    for p in node.properties:
        if p.name == name:
            return p
    raise KeyError(f"property {name!r} not found in node {_get_node_name(node)!r}")


def _encode_fixed_string(s: str, length: int) -> bytes:
    raw = s.encode("utf-8") + b"\x00"
    if len(raw) > length:
        return raw[:length]
    return raw + b"\x00" * (length - len(raw))


# ──────────────────────────────────────────────────────────────────────
# The three patches
# ──────────────────────────────────────────────────────────────────────


def _patch_dt_blob(dt_blob: bytes) -> bytes:
    """Apply the post-restore DT identity rewrites. Returns the new blob.

    Raises if the DT structure doesn't match what we expect.
    """
    root, end = _parse_node(dt_blob, 0)
    if end != len(dt_blob):
        raise ValueError(
            f"DT parse length mismatch: ended at {end}, blob is {len(dt_blob)}"
        )
    root_name = _get_node_name(root)
    if root_name != "device-tree":
        raise ValueError(f"expected root node 'device-tree', got {root_name!r}")

    changed = []

    # 1. root/model → iPhone17,3
    p = _find_property(root, "model")
    new_val = _encode_fixed_string("iPhone17,3", p.length)
    if p.value != new_val:
        before = p.value.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        p.value = new_val
        changed.append(f"model: '{before}' -> 'iPhone17,3'")

    # 2. root/target-type → D47
    p = _find_property(root, "target-type")
    new_val = _encode_fixed_string("D47", p.length)
    if p.value != new_val:
        before = p.value.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        p.value = new_val
        changed.append(f"target-type: '{before}' -> 'D47'")

    # 3. root/compatible reorder
    p = _find_property(root, "compatible")
    new_compat_body = (
        b"D47AP\x00"
        + b"VPHONE600AP\x00"
        + b"AppleVirtualPlatformARM\x00"
    )
    if len(new_compat_body) > p.length:
        raise ValueError(
            f"compatible body {len(new_compat_body)}B > slot {p.length}B"
        )
    new_compat = new_compat_body + b"\x00" * (p.length - len(new_compat_body))
    if p.value != new_compat:
        before_parts = [
            x.decode("utf-8", errors="replace")
            for x in p.value.split(b"\x00")
            if x
        ]
        p.value = new_compat
        changed.append(
            f"compatible: {before_parts} -> ['D47AP', 'VPHONE600AP', "
            f"'AppleVirtualPlatformARM']"
        )

    if not changed:
        return dt_blob

    for c in changed:
        print(f"  [+] {c}")
    return _serialize_node(root)


# ──────────────────────────────────────────────────────────────────────
# img4 / IM4P round-trip
# ──────────────────────────────────────────────────────────────────────


def patch_devicetree_file(path: str, *, dry_run: bool = False) -> int:
    """Patch a devicetree.img4 (preferred) or devicetree.im4p file in
    place. Returns the number of property changes applied (0 if the file
    was already in the target state).
    """
    with open(path, "rb") as f:
        data = f.read()

    # Auto-detect IMG4 vs bare IM4P.
    try:
        img4 = pyimg4.IMG4(data)
        is_img4 = True
        im4p = img4.im4p
    except Exception:
        img4 = None
        is_img4 = False
        im4p = pyimg4.IM4P(data)

    if im4p.fourcc != "dtre":
        raise ValueError(
            f"{path}: expected DT payload (fourcc='dtre'), got fourcc={im4p.fourcc!r}"
        )
    print(
        f"  [.] {path}: {'IMG4' if is_img4 else 'IM4P'}  "
        f"desc={im4p.description!r}  payload_compression={im4p.payload.compression}"
    )

    # Decompress
    original_compression = im4p.payload.compression
    if original_compression != pyimg4.Compression.NONE:
        im4p.payload.decompress()
    dt_blob = bytes(im4p.payload.output().data)
    print(f"  [.] DT blob: {len(dt_blob)} bytes")

    # Apply patches
    new_dt = _patch_dt_blob(dt_blob)
    if new_dt == dt_blob:
        print(f"  [.] {path}: DT already in target state — no change")
        return 0
    if len(new_dt) != len(dt_blob):
        # Should be impossible because we preserve every property's slot length,
        # but bail loudly if invariants drift.
        raise RuntimeError(
            f"DT size changed: {len(dt_blob)} -> {len(new_dt)} bytes "
            f"(would break IM4P offsets)"
        )

    # Build new IM4P with patched payload, preserving compression mode.
    new_payload = pyimg4.IM4PData(data=new_dt)
    if original_compression != pyimg4.Compression.NONE:
        new_payload.compress(original_compression)
    new_im4p = pyimg4.IM4P(
        fourcc=im4p.fourcc,
        description=im4p.description,
        payload=new_payload,
    )

    if is_img4:
        new_img4 = pyimg4.IMG4(im4p=new_im4p, im4m=img4.im4m, im4r=img4.im4r)
        out_bytes = new_img4.output()
    else:
        out_bytes = new_im4p.output()

    print(f"  [.] output size: {len(out_bytes)} bytes (was {len(data)})")
    if dry_run:
        print(f"  [.] dry-run — not writing back")
        return 0

    with open(path, "wb") as f:
        f.write(out_bytes)
    print(f"  [+] wrote {path}")
    return 1


def _main(argv):
    if len(argv) < 2:
        print(
            "Usage: cfw_patch_post_restore_dt.py <devicetree.img4|im4p> [--dry-run]",
            file=sys.stderr,
        )
        return 2
    path = argv[1]
    dry_run = "--dry-run" in argv[2:]
    try:
        patch_devicetree_file(path, dry_run=dry_run)
    except Exception as e:
        print(f"[-] {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
