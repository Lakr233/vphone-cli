#!/usr/bin/env python3
"""KASLR slide of Basil's kernel (iOS 27.2 / 24B119) without a guest panic, plus a kcall10 client.

slide = (VBAR_EL1 & 0xffffffff) - 0x8cab000 (link-time VBAR);  runtime = link-time + slide.
The slide is one number for the whole fileset image (text, data, text_exec).
Validated on boots G,H,I: panic lr == 0xfffffe0008ca7850 + slide.  Boot K: a call to
`mov w0,#1; ret` (link 0x8cd8a78) through kcall10 returned 1 and the VM survived.
XNU's panic line "Kernel slide" is this slide + 0x4000.

usage: kslide.py                     -> SLIDE <hex>
       kslide.py --read LINK...      -> *(uint64) at kernel link-time addresses (ldr x0,[x0]; ret gadget)
       kslide.py --call LINK [a...]  -> one kcall10 call, prints kx's result line
       kslide.py --selftest          -> slide(lr) on the saved panic logs
"""
import os, re, socket, subprocess, sys

VBAR_LINK = 0x8cab000
GADGET_LDR_X0 = 0xfffffe0008d1ebc4  # ldr x0,[x0] ; ret  (8-byte function in __text)
SOCK = os.path.expanduser("~/.vphone/machines/Basil/vphone.sock")
LOG = os.path.expanduser("~/Library/Logs/vphone-launchpad/Basil.log")
VSP = "/tmp/jbresearch/wq2/vsp.py"
BSH = "/tmp/bsh.sh"
KX = "/private/var/tmp/kx.out"
KXBIN = "/tmp/jbresearch/kx"


def ping():
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(8)
        s.connect(SOCK)
        s.sendall(b'{"t":"ping"}\n')
        ok = b'"ok":true' in s.recv(4096)
        s.close()
        return ok
    except OSError:
        return False


def vbar():
    if not ping():
        sys.exit("VM not running (ping failed)")
    lines = [l for l in open(LOG, errors="replace") if "GDB debug stub listening" in l]
    if not lines:
        sys.exit("no stub line in the log")
    port = lines[-1].rsplit(":", 1)[1].strip()
    # vsp.py must run to its `D` (detach): never cut its output short with grep -m
    p = subprocess.run(["python3", VSP, port], cwd=os.path.dirname(VSP),
                       capture_output=True, text=True, timeout=60)
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"VBAR: 0x([0-9a-f]+)", out)
    if not m:
        sys.exit("vsp.py gave no VBAR:\n" + out[-400:])
    if not ping():
        sys.exit("VM died during the stub read")
    return int(m.group(1), 16)


_slide = None


def slide():
    global _slide
    if _slide is None:
        s = (vbar() & 0xffffffff) - VBAR_LINK
        assert 0 < s < 0x1_0000_0000, hex(s)
        _slide = s
    return _slide


def calls(specs):
    """Run kx once per (link, args) in one root shell session; return kx's result lines."""
    s = slide()
    script = ":\nexport PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin\nrm -f /private/var/tmp/kx.out\n"
    for link, args in specs:
        script += f"/private/var/tmp/kx {link + s:#x} " + " ".join(f"{a:#x}" for a in args) + "\n"
    script += f"cat {KX}\n"
    push_kx()
    p = subprocess.run([BSH, "/dev/stdin", "6"], input=script, capture_output=True, text=True, timeout=120)
    lines = [l for l in (p.stdout + p.stderr).splitlines() if l.startswith(("r=", "bad arg"))]
    if len(lines) != len(specs):
        print(f"kx: {len(lines)} of {len(specs)} result lines (VM panicked? check {LOG})", file=sys.stderr)
    return lines


def value(line):
    return int(re.search(r"r=0x([0-9a-f]+)", line).group(1), 16)


def kread(addrs):
    """*(uint64) at kernel LINK-TIME addresses; both the gadget and the address get the slide."""
    return [value(l) for l in calls([(GADGET_LDR_X0, [a + slide()]) for a in addrs])]


def selftest():
    for boot in "GHI":
        t = open(f"/tmp/jbresearch/basil/panic{boot}.log", errors="replace").read()
        lr = int(re.search(r"panic\(cpu \d+ caller 0x[0-9a-f]+\): [^\n]*?lr 0x([0-9a-f]+)", t).group(1), 16)
        xnu = int(re.search(r"Kernel slide:\s+0x([0-9a-f]+)", t).group(1), 16)
        s = lr - 0xfffffe0008ca7850
        assert s > 0 and s % 0x4000 == 0 and xnu == s + 0x4000, (hex(s), hex(xnu))
        print(f"boot {boot}: slide(lr) = {s:#x}   XNU 'Kernel slide' = {xnu:#x} (= slide + 0x4000)")


def main():
    a = sys.argv[1:]
    if "--selftest" in a:
        return selftest()
    if "--read" in a:
        s = slide()
        for link, v in zip([int(x, 16) for x in a[a.index("--read") + 1:]], kread([int(x, 16) for x in a[a.index("--read") + 1:]])):
            print(f"{link:#x} (slide {s:#x}) -> {v:#018x}")
        return
    if "--call" in a:
        rest = [int(x, 16) for x in a[a.index("--call") + 1:]]
        args = [x + slide() if x >= 0xfffffe0000000000 else x for x in rest[1:]]  # kernel addresses are slid
        print(f"slide {slide():#x}; " + calls([(rest[0], args)])[0])
        return
    print(f"SLIDE {slide():#x}")




def push_kx():
    """kx lives in /private/var/tmp, which the guest wipes on every boot: push it before use."""
    import json, shutil
    if not os.path.exists(KXBIN):
        sys.exit(f"kx binary missing: {KXBIN}")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(SOCK)
    s.sendall(json.dumps({"t": "push", "local": KXBIN, "path": "/private/var/tmp/kx", "mode": "755"}).encode() + b"\n")
    ok = b'"ok":true' in s.recv(4096)
    s.close()
    if not ok:
        sys.exit("push of kx failed")


if __name__ == "__main__":
    main()
