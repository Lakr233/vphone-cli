#!/usr/bin/env python3
"""Validate per-VM Host CMIO registrations and loopback frame isolation."""

from __future__ import annotations

import glob
import json
import socket
import struct
import sys
import time
from pathlib import Path
from urllib.parse import urlparse


REGISTRY = Path.home() / "Library/Group Containers/group.com.vp.vphone.shared/registrations"
HEADER = struct.Struct("<IIIIIQI")
MAGIC = 0x31465056
VERSION = 1


def read_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("peer closed before the expected payload arrived")
        data.extend(chunk)
    return bytes(data)


def probe(registration: dict) -> dict:
    endpoint = urlparse(registration["endpoint"])
    if endpoint.scheme != "tcp" or endpoint.hostname != "127.0.0.1":
        raise RuntimeError(f"endpoint is not loopback TCP: {registration['endpoint']}")
    with socket.create_connection((endpoint.hostname, endpoint.port), timeout=3) as sock:
        sock.settimeout(5)
        hello = bytearray()
        while not hello.endswith(b"\n"):
            hello.extend(sock.recv(1))
        expected = (
            f"VPHONE-CMIO/1 {registration['vmID']} "
            f"{registration['generation']}\n"
        )
        if hello.decode("utf-8", "replace") != expected:
            raise RuntimeError(
                f"handshake mismatch: got {hello!r}, expected {expected!r}"
            )
        header = HEADER.unpack(read_exact(sock, HEADER.size))
        magic, version, width, height, bytes_per_row, host_time_ns, payload = header
        if magic != MAGIC or version != VERSION:
            raise RuntimeError(f"invalid frame header: {header!r}")
        if payload != bytes_per_row * height:
            raise RuntimeError(f"invalid frame payload length: {header!r}")
        read_exact(sock, payload)
        return {
            "displayName": registration["displayName"],
            "pid": registration["pid"],
            "endpoint": registration["endpoint"],
            "width": width,
            "height": height,
            "bytesPerRow": bytes_per_row,
            "payload": payload,
            "hostTimeNS": host_time_ns,
        }


def main() -> int:
    registrations = []
    for path in sorted(glob.glob(str(REGISTRY / "*.json"))):
        try:
            value = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            continue
        # Foundation Date encodes seconds since 2001-01-01, unlike Unix time.
        updated_at = float(value.get("updatedAt", 0)) + 978307200
        age = time.time() - updated_at
        if age <= 5:
            registrations.append(value)

    if not registrations:
        print("[multivm-probe] no fresh registrations", file=sys.stderr)
        return 2
    vm_ids = [r["vmID"] for r in registrations]
    endpoints = [r["endpoint"] for r in registrations]
    if len(vm_ids) != len(set(vm_ids)) or len(endpoints) != len(set(endpoints)):
        print("[multivm-probe] duplicate VM or endpoint identity", file=sys.stderr)
        return 3

    print(f"[multivm-probe] fresh registrations={len(registrations)}")
    failures = 0
    for registration in registrations:
        try:
            print("[multivm-probe]", json.dumps(probe(registration), sort_keys=True))
        except Exception as exc:  # noqa: BLE001 - diagnostics should continue
            failures += 1
            print(
                f"[multivm-probe] {registration['displayName']}: {exc}",
                file=sys.stderr,
            )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
