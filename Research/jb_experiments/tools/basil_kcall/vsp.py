#!/usr/bin/env python3
"""vphone kernel debug-stub client, mirroring VPhoneGuestDebugStub.swift exactly:
+ -> QStartNoAckMode -> ? -> QThreadSuffixSupported -> reads -> D (always, in finally)."""
import socket, sys, time

class Session:
    def __init__(self, port, timeout=3.0):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.s.settimeout(timeout); self.buf = b""; self.ack = True
    def _write(self, b):
        self.s.sendall(b)
    def send(self, payload):
        raw = payload.encode(); c = sum(raw) & 0xff
        self._write(b"$" + raw + b"#" + ("%02x" % c).encode())
    @staticmethod
    def decode(raw):
        out = bytearray(); i = 0
        while i < len(raw):
            b = raw[i]
            if b == 0x7d and i + 1 < len(raw): out.append(raw[i+1] ^ 0x20); i += 2
            elif b == 0x2a and i + 1 < len(raw) and out:
                n = raw[i+1] - 29
                if n > 0: out += bytes([out[-1]]) * n
                i += 2
            else: out.append(b); i += 1
        return bytes(out)
    def receive(self):
        while True:
            st = self.buf.find(b"$")
            if st >= 0:
                en = self.buf.find(b"#", st)
                if en >= 0 and len(self.buf) >= en + 3:
                    raw = self.buf[st+1:en]; chk = self.buf[en+1:en+3]
                    self.buf = self.buf[en+3:]
                    if self.ack:
                        if int(chk, 16) != (sum(raw) & 0xff): raise RuntimeError("bad checksum")
                        self._write(b"+")
                    return self.decode(raw).decode(errors="replace")
            chunk = self.s.recv(4096)
            if not chunk: raise RuntimeError("stub closed the connection")
            self.buf += chunk
    def request(self, p):
        self.send(p); return self.receive()
    def start(self):
        self._write(b"+")
        if self.request("QStartNoAckMode") == "OK": self.ack = False
        stop = self.request("?")
        cpus = []
        for pair in stop.split(";"):
            if pair.startswith("threads:"):
                cpus = [int(t, 16) for t in pair[8:].split(",")]
        if not cpus:
            r = self.request("qfThreadInfo")
            while r.startswith("m"):
                cpus += [int(t, 16) for t in r[1:].split(",")]; r = self.request("qsThreadInfo")
        if self.request("QThreadSuffixSupported") != "OK": raise RuntimeError("no thread suffix")
        return stop, cpus
    def regnums(self, names):
        nums = {}
        for n in range(1024):
            r = self.request("qRegisterInfo%x" % n)
            if not r or r.startswith("E"): break
            f = dict(p.split(":", 1) for p in r.split(";") if ":" in p)
            for k in ("name", "alt-name"):
                if f.get(k) in names and f.get(k) not in nums: nums[f[k]] = n
            if len(nums) == len(names): break
        return nums
    def reg(self, n, cpu):
        r = self.request("p%x;thread:%x;" % (n, cpu))
        if r.startswith("E") or len(r) % 2: raise RuntimeError("register %d cpu %x: %s" % (n, cpu, r[:32]))
        return int.from_bytes(bytes.fromhex(r), "little")
    def mem(self, addr, size):
        r = self.request("m%x,%x" % (addr, size))
        if not r or r.startswith("E"): return None
        return bytes.fromhex(r)
    def detach(self):
        try: self.request("D")
        except Exception: pass

if __name__ == "__main__":
    port = int(sys.argv[1])
    s = Session(port)
    try:
        stop, cpus = s.start()
        print("stop:", stop[:200]); print("cpus:", [hex(c) for c in cpus])
        nums = s.regnums({"ttbr1_el1", "vbar_el1", "ttbr0_el1", "tpidr_el1", "cpsr", "pc"})
        print("regnums:", {k: hex(v) for k, v in nums.items()})
        vals = {c: {k: s.reg(n, c) for k, n in nums.items()} for c in cpus}
        for c in cpus:
            print("cpu %x:" % c, {k: hex(v) for k, v in vals[c].items()})
        k = vals[cpus[0]]
        print("TTBR1 root:", hex(k["ttbr1_el1"] & 0x0000_FFFF_FFFF_C000), "VBAR:", hex(k["vbar_el1"]))
    finally:
        s.detach(); s.s.close()
