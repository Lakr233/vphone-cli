"""seputil patch module."""

try:
    from . import cfw_records as records
except ImportError:  # direct self-test / standalone execution
    import cfw_records as records


def patch_seputil(filepath):
    """Dynamically find and patch the gigalocker path format string in seputil.

    Anchor: The format string "/%s.gl" used by seputil to construct the
    gigalocker file path as "{mountpoint}/{uuid}.gl".

    Patching "%s" to "AA" in "/%s.gl" makes it "/AA.gl", so the
    full path becomes /mnt7/AA.gl regardless of the device's UUID.
    The actual .gl file on disk is also renamed to AA.gl.
    """
    data = bytearray(open(filepath, "rb").read())

    # Search for the format string "/%s.gl\0" — this is the gigalocker
    # filename pattern where %s gets replaced with the device UUID.
    anchor = b"/%s.gl\x00"
    offset = data.find(anchor)

    if offset < 0:
        print("  [-] Format string '/%s.gl' not found in seputil")
        return False

    # The %s is at offset+1 (2 bytes: 0x25 0x73)
    pct_s_off = offset + 1
    original = bytes(data[offset : offset + len(anchor)])
    print(f"  Found format string at 0x{offset:X}: {original!r}")

    print(f"  Before: {bytes(data[offset : offset + 7]).hex(' ')}")

    # Replace %s (2 bytes) with AA — turns "/%s.gl" into "/AA.gl"
    data[pct_s_off] = ord("A")
    data[pct_s_off + 1] = ord("A")

    print(f"  After:  {bytes(data[offset : offset + 7]).hex(' ')}")

    records.set_group("seputil")
    records.record_file_write(filepath, data, component="seputil", sites=[
        records.site(pct_s_off, 2, "seputil.gigalocker_uuid",
                     "gigalocker path format '/%s.gl' -> '/AA.gl'"),
    ])
    open(filepath, "wb").write(data)
    print(f"  [+] Patched at 0x{pct_s_off:X}: %s -> AA")
    print(f"      /{anchor[1:-1].decode()} -> /AA.gl")
    return True
