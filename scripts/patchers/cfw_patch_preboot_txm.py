#!/usr/bin/env python3
"""cfw_patch_preboot_txm.py - replace Preboot TXM payload in-place.

The input Preboot file is an IMG4 used by normal boot. Keep its IMG4
manifest/restore metadata and only replace the IM4P payload with the already
patched release TXM payload built by the firmware patch flow.
"""

import sys

import pyimg4


def _payload_bytes(im4p):
    if im4p.payload.compression != pyimg4.Compression.NONE:
        im4p.payload.decompress()
    return bytes(im4p.payload.output().data)


def _read_im4p(path):
    data = open(path, "rb").read()
    try:
        return pyimg4.IMG4(data).im4p
    except Exception:
        return pyimg4.IM4P(data)


def _der_add_len(data, extra):
    if not data or data[0] != 0x30:
        raise ValueError("rebuilt IM4P missing top-level DER sequence")

    first = data[1]
    if first & 0x80:
        n = first & 0x7F
        start = 2
        end = start + n
        old = int.from_bytes(data[start:end], "big")
        data[start:end] = (old + extra).to_bytes(n, "big")
    else:
        old = first
        new = old + extra
        if new > 0x7F:
            raise ValueError("rebuilt IM4P length grew past short DER form")
        data[1] = new


def _append_payp_if_present(original_im4p_bytes, rebuilt_im4p_bytes):
    marker = b"PAYP"
    payp_offset = original_im4p_bytes.rfind(marker)
    if payp_offset < 10:
        return rebuilt_im4p_bytes

    payp = original_im4p_bytes[payp_offset - 10 :]
    out = bytearray(rebuilt_im4p_bytes)
    _der_add_len(out, len(payp))
    out.extend(payp)
    return bytes(out)


def patch_preboot_txm(live_img4_path, patched_txm_path):
    live_data = open(live_img4_path, "rb").read()
    live_img4 = pyimg4.IMG4(live_data)
    live_im4p = live_img4.im4p
    source_im4p = _read_im4p(patched_txm_path)

    if live_im4p.fourcc != "trxm":
        raise ValueError(f"{live_img4_path}: expected live TXM fourcc 'trxm', got {live_im4p.fourcc!r}")
    if source_im4p.fourcc != "trxm":
        raise ValueError(f"{patched_txm_path}: expected source TXM fourcc 'trxm', got {source_im4p.fourcc!r}")

    live_compression = live_im4p.payload.compression
    live_im4p_bytes = live_im4p.output()
    source_payload = _payload_bytes(source_im4p)

    new_payload = pyimg4.IM4PData(data=source_payload)
    if live_compression != pyimg4.Compression.NONE:
        new_payload.compress(live_compression)
    new_im4p = pyimg4.IM4P(
        fourcc=live_im4p.fourcc,
        description=live_im4p.description,
        payload=new_payload,
    )
    new_im4p_data = _append_payp_if_present(live_im4p_bytes, new_im4p.output())
    new_im4p = pyimg4.IM4P(new_im4p_data)

    new_img4 = pyimg4.IMG4(im4p=new_im4p, im4m=live_img4.im4m, im4r=live_img4.im4r)
    out = new_img4.output()
    with open(live_img4_path, "wb") as f:
        f.write(out)

    print(f"  [.] live TXM payload compression: {live_compression}")
    print(f"  [.] patched TXM payload bytes: {len(source_payload)}")
    print(f"  [+] rewrote {live_img4_path} preserving live IMG4 metadata")


def main(argv):
    if len(argv) != 3:
        print("Usage: cfw_patch_preboot_txm.py <live-preboot-txm.img4> <patched-txm.img4|im4p>", file=sys.stderr)
        return 2
    patch_preboot_txm(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
