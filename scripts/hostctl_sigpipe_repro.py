#!/usr/bin/env python3
"""Reproduce (or falsify) issue #472: a host-control client that disconnects
before it has read the whole reply kills the vphone-cli process with SIGPIPE.

    scripts/hostctl_sigpipe_repro.py <socket-path> [--pid PID]
    scripts/hostctl_sigpipe_repro.py --vm <name> [--library ~/.vphone/VMs] [--pid PID]

What it does:

  1. warm-up: waits until the control socket answers a small request, so the
     run never measures "the VM is still booting" instead of the bug;
  2. trigger: sends {"t":"screenshot","path":...}, reads the first 4 KiB of the
     reply and closes the socket while the server is still writing. The reply to
     a screenshot is large (base64 JPEG of the compact screen), so the server
     keeps writing into a socket whose peer is gone. SO_RCVBUF is pinned to
     4 KiB first so this holds even for a short reply;
  3. verdict: waits two seconds, then checks the process (with --pid, when the
     launcher knows it) and sends one more request. A surviving server answers
     it; a killed one refuses the connection.

Exit status: 0 = survived (fix in place), 1 = dead / stopped serving (bug
present), 2 = inconclusive (no socket, no reply, unrelated error).

Against a build without the fix the process exits silently: no crash report is
generated, the launch wrapper only reports "exit". See issue #472.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time

WARMUP_TIMEOUT_S = 300.0
FOLLOWUP_GRACE_S = 2.0


def connect(path: str, rcvbuf: int | None = None) -> socket.socket:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    if rcvbuf is not None:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.connect(path)
    return s


def request(path: str, payload: dict, *, read_bytes: int | None = None,
            rcvbuf: int | None = None) -> tuple[bytes, bytes]:
    """Send one request. Returns (first `read_bytes` bytes, rest of the reply).

    With `read_bytes` set the socket is closed *before* the rest of the reply
    has been read - that is the #472 trigger.
    """
    s = connect(path, rcvbuf=rcvbuf)
    try:
        s.sendall(json.dumps(payload).encode() + b"\n")
        head = s.recv(read_bytes) if read_bytes else b""
        tail = b""
        if read_bytes is None:
            while not tail.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                tail += chunk
        return head, tail
    finally:
        s.close()


def alive(pid: int | None) -> bool:
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def warm_up(path: str, out: str, deadline: float) -> bool:
    """Wait until a screenshot request returns a full compact image.

    A ready VM is not enough: the trigger only means something when the reply
    is large enough that the server is still writing when the client closes,
    so the warm-up insists on an image of at least 10 KB of base64.
    """
    last = "no reply yet"
    while time.monotonic() < deadline:
        try:
            _, reply = request(path, {"t": "screenshot", "path": out})
            body = json.loads(reply.decode("utf-8", "replace").strip())
            image = body.get("image")
            if body.get("ok") is True and isinstance(image, str) and len(image) > 10_000:
                return True
            last = f"ok={body.get('ok')} image={len(image) if isinstance(image, str) else image}"
        except (OSError, ValueError) as exc:
            last = str(exc)
        time.sleep(3.0)
    print(f"inconclusive: socket never returned a full screenshot reply ({last})")
    return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("socket_path", nargs="?", help="path to vphone.sock")
    parser.add_argument("--vm", help="VM name; resolves <library>/<name>/vphone.sock")
    parser.add_argument("--library", default=os.path.expanduser("~/.vphone/VMs"))
    parser.add_argument("--pid", type=int, help="pid of the vphone-cli process, if known")
    parser.add_argument("--out", default="/tmp/vphone-sigpipe-repro.png",
                        help="where the screenshot command should save its file")
    parser.add_argument("--warmup-timeout", type=float, default=WARMUP_TIMEOUT_S)
    parser.add_argument("--no-warmup", action="store_true",
                        help="skip the readiness wait (server is known to be up)")
    args = parser.parse_args(argv)

    sock_path = args.socket_path
    if not sock_path and args.vm:
        sock_path = os.path.join(args.library, args.vm, "vphone.sock")
    if not sock_path or not os.path.exists(sock_path):
        print(f"inconclusive: no control socket at {sock_path!r}")
        return 2

    deadline = time.monotonic() + args.warmup_timeout
    if not args.no_warmup and not warm_up(sock_path, args.out, deadline):
        return 2

    # 1. trigger: read only the first 4 KiB and close while the server writes.
    try:
        head, _ = request(sock_path, {"t": "screenshot", "path": args.out},
                          read_bytes=4096, rcvbuf=4096)
    except OSError as exc:
        print(f"inconclusive: trigger request failed: {exc}")
        return 2
    print(f"trigger: read {len(head)} bytes of the reply, then closed the socket")
    if not head.startswith(b"{"):
        print(f"inconclusive: reply does not look like a control response: {head[:80]!r}")
        return 2

    # 2. verdict: the server must still be there after the write it was doing.
    time.sleep(FOLLOWUP_GRACE_S)
    if not alive(args.pid):
        print(f"FAIL: process {args.pid} is gone - SIGPIPE on write to a "
              f"disconnected client killed it (issue #472)")
        return 1

    try:
        _, reply = request(sock_path, {"t": "screenshot", "screen": False})
        body = json.loads(reply.decode("utf-8", "replace").strip())
    except (OSError, ValueError) as exc:
        print(f"FAIL: server did not answer after the early disconnect: {exc}")
        return 1

    if body.get("ok") is not True:
        print(f"FAIL: follow-up reply was not ok: {reply[:160]!r}")
        return 1

    print("PASS: server survived the early disconnect and kept serving")
    if "image" in body:
        print("note: 'screen':false still attached an image - the doc comment "
              "promises the flag suppresses it for every command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
