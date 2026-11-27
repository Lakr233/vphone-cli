#!/usr/bin/env python3
"""
mptcp_ip_server.py — IP-level (L3) rewrite of mptcp_dfin_reach.py for hosts that are not
on the same L2 segment as the target. Original file is left untouched.

Handshake it performs, per connection:
  client SYN (MP_CAPABLE)          -> server SYN-ACK with MP_CAPABLE v1 + MPCAP_CHECKSUM_CBIT
  client ACK (MP_CAPABLE, keys)    -> server ACK
  client data (DSS)                -> server sends ONE DSS segment, see below, and nothing else
                                      (no spray, no DATA_FIN, no RST, no FIN)

Modes (all data_len=1, one payload byte, deliberately wrong checksum 0xDEAD):
  fail     DSS without DATA_FIN. Safe variant of the report's Experiment 4/5: XNU should
           run mptcp_validate_csum on an already dequeued mbuf, answer MP_FAIL (subtype 6)
           and fall back to plain TCP. Expected on wire: MP_FAIL from the device.
  dfin     DSS with DATA_FIN. NOT implemented on purpose: on 23F84 this is the panic path
           of the report (m_freem on an mbuf still in so_rcv). Refuses to run.

What it does NOT do, by design:
  - no iptables/nft changes. The Linux kernel answers RST to a SYN for a port that has
    no listener, so a real XNU client cannot complete the handshake unless outgoing RSTs
    for this port are dropped. --check-rst-filter only verifies whether such a filter is
    present and tells the operator; it never installs one.

Transport: receive via AF_PACKET sniff on one interface (tcp/<port> BPF filter),
send via a raw L3 socket. No scapy sendp/L2, no ARP handling.

Usage:
  mptcp_ip_server.py --iface eth0 --port 9999 [--mode fail] [--pcap out.pcap]
                     [--count 1] [--server-key-hex 00..ff]
  mptcp_ip_server.py --check-rst-filter --iface eth0 --port 9999
"""

import argparse
import hashlib
import struct
import subprocess
import sys
import time

from scapy.all import IP, TCP, Raw, sniff, conf, L3RawSocket

MPTCP_KIND = 30
MPO_CAPABLE = 0
MPO_DSS = 2
MPCAP_PROPOSAL_SBIT = 0x01
MPCAP_CHECKSUM_CBIT = 0x80
MDSS_A = 0x01
MDSS_M = 0x04

MP_FAIL_SUBTYPE = 6


def xnu_generate_idsn(key: int) -> int:
    # Same as mptcp_dfin_reach.py: SHA-256 of the key in network byte order, bytes [24:32] as BE.
    key_be = struct.pack('!Q', key)
    digest = hashlib.sha256(key_be).digest()
    return struct.unpack('>Q', digest[24:32])[0]


def mp_capable_synack(server_key: int, version: int = 1) -> bytes:
    # SYN-ACK carries sender's key only (RFC 8684 §3.1). A bit = checksum required.
    subtype_ver = (MPO_CAPABLE << 4) | (version & 0x0F)
    flags = MPCAP_PROPOSAL_SBIT | MPCAP_CHECKSUM_CBIT
    return struct.pack('!BB', subtype_ver, flags) + struct.pack('!Q', server_key)


def mp_capable_with_data(server_key: int, version: int = 1) -> bytes:
    # Server's key in the first data packet (RFC 8684 3.1, checksum mode): kind 0, len 22, flags B+?
    # Apple's client puts MP_CAPABLE in the 4th packet too; match it: subtype 0 ver 1, flags 0x81.
    return struct.pack('!BB', (MPO_CAPABLE << 4) | (version & 0x0F), MPCAP_PROPOSAL_SBIT | MPCAP_CHECKSUM_CBIT) + struct.pack('!Q', server_key)


def dss_bad_csum_no_dfin(data_ack: int, dsn: int, sseq: int, dlen: int = 1) -> bytes:
    # 32-bit DataACK + 32-bit DSN + subflow seq + data_len + checksum (checksum present because
    # XNU negotiated MPTCPF_CHECKSUM; mptcp_do_dss_opt_meat masks flags with A|a|M|m).
    flags = MDSS_M | MDSS_A
    subtype_rsv = (MPO_DSS << 4)
    return (struct.pack('!BB', subtype_rsv, flags) +
            struct.pack('!I', data_ack & 0xFFFFFFFF) +
            struct.pack('!I', dsn & 0xFFFFFFFF) +
            struct.pack('!I', sseq & 0xFFFFFFFF) +
            struct.pack('!H', dlen) +
            struct.pack('!H', 0xDEAD))


def mptcp_options(tcp) -> list:
    out = []
    for kind, val in tcp.options:
        if kind == MPTCP_KIND:
            out.append(val if isinstance(val, (bytes, bytearray)) else bytes(val))
    return out


def parse_dss(raw: bytes):
    if len(raw) < 4:
        return None
    flags = raw[1]
    off = 2
    dack = None
    if flags & 0x02:
        dack = struct.unpack('!Q', raw[off:off + 8])[0]
        off += 8
    elif flags & 0x01:
        dack = struct.unpack('!I', raw[off:off + 4])[0]
        off += 4
    dsn = sseq = dlen = None
    if flags & 0x08:
        dsn = struct.unpack('!Q', raw[off:off + 8])[0]
        off += 8
    elif flags & 0x04:
        dsn = struct.unpack('!I', raw[off:off + 4])[0]
        off += 4
    if dsn is not None and off + 6 <= len(raw):
        sseq = struct.unpack('!I', raw[off:off + 4])[0]
        dlen = struct.unpack('!H', raw[off + 4:off + 6])[0]
    return flags, dack, dsn, sseq, dlen


class Server:
    def __init__(self, args):
        self.iface = args.iface
        self.port = args.port
        self.mode = args.mode
        self.count = args.count
        self.server_key = int(args.server_key_hex, 16) if args.server_key_hex else int.from_bytes(
            hashlib.sha256(str(time.time_ns()).encode()).digest()[:8], 'big') or 1
        self.sock = L3RawSocket(iface=self.iface)
        self.conns = {}
        self.triggered = 0
        self.done = False
        self.log_lines = []

    def log(self, s):
        line = f"{time.strftime('%H:%M:%S')} {s}"
        print(line, flush=True)
        self.log_lines.append(line)

    def send(self, src_ip, dst_ip, sport, dport, flags, seq, ack, opts=(), data=b''):
        pkt = IP(src=src_ip, dst=dst_ip) / TCP(sport=sport, dport=dport, flags=flags, seq=seq,
                                               ack=ack, window=65535, options=list(opts))
        if data:
            pkt = pkt / Raw(load=data)
        self.sock.send(pkt)

    def handle(self, pkt):
        if IP not in pkt or TCP not in pkt:
            return
        ip, tcp = pkt[IP], pkt[TCP]
        if tcp.dport != self.port:
            return
        fl = int(tcp.flags)
        src_ip, sport = ip.src, tcp.sport
        server_ip = ip.dst
        key = (src_ip, sport)
        opts = mptcp_options(tcp)
        mptcp = opts[0] if opts else None

        if fl & 0x04:
            st = self.conns.get(key, {})
            self.log(f"[RST] from {src_ip}:{sport} seq={tcp.seq:#010x} ack={tcp.ack:#010x} "
                     f"state={st.get('state', 'NONE')}")
            return

        if mptcp:
            subtype = (mptcp[0] >> 4) & 0x0F
            if subtype == MP_FAIL_SUBTYPE:
                st = self.conns.get(key, {})
                self.log(f"[!!!] MP_FAIL from {src_ip}:{sport} ack={tcp.ack:#010x} "
                         f"(server_isn+{((tcp.ack - st.get('isn', tcp.ack - 2)) & 0xFFFFFFFF)}) "
                         f"state={st.get('state', 'NONE')}")

        if fl & 0x02 and not (fl & 0x10):
            if not mptcp or len(mptcp) < 2:
                self.log(f"[~] SYN from {src_ip}:{sport} without MP_CAPABLE — ignored (not MPTCP)")
                return
            version = mptcp[0] & 0x0F
            isn = int.from_bytes(hashlib.sha256(f"{src_ip}{sport}{time.time_ns()}".encode()).digest()[:4], 'big')
            idsn64 = xnu_generate_idsn(self.server_key)
            self.conns[key] = {
                'state': 'SYN_RCVD', 'isn': isn, 'server_seq': (isn + 1) & 0xFFFFFFFF,
                'client_seq': (tcp.seq + 1) & 0xFFFFFFFF, 'version': version,
                'dsn': (idsn64 + 1) & 0xFFFFFFFF,
            }
            self.log(f"[+] SYN (MP_CAPABLE v{version}) {src_ip}:{sport} -> SYN-ACK with CHECKSUM bit; "
                     f"server_key={self.server_key:#018x} isn={isn:#010x}")
            self.send(server_ip, src_ip, self.port, sport, 'SA', isn, (tcp.seq + 1) & 0xFFFFFFFF,
                      [('MSS', 1460), ('NOP', None), ('NOP', None), ('WScale', 7),
                       (MPTCP_KIND, mp_capable_synack(self.server_key, version))])
            return

        if (fl & 0x10) and key in self.conns:
            st = self.conns[key]
            if st['state'] == 'SYN_RCVD':
                st['client_seq'] = tcp.seq
                st['state'] = 'ESTABLISHED'
                sub = (mptcp[0] >> 4) & 0x0F if mptcp else None
                self.log(f"[+] 3rd ACK from {src_ip}:{sport} subtype={sub} "
                         f"(MPO_CAPABLE={MPO_CAPABLE}) tcp.ack={tcp.ack:#010x} "
                         f"expected={st['server_seq']:#010x}")
                # v2: XNU sends MP_CAPABLE in the 4th packet (with data) as well; the server must too,
                # otherwise the meta-connection stays half-open and later DSS options are ignored.
                self.send(server_ip, src_ip, self.port, sport, 'PA', st['server_seq'],
                          st['client_seq'], [(MPTCP_KIND, mp_capable_with_data(self.server_key, st['version']))],
                          data=b'\x00')
                return

            if st['state'] == 'ESTABLISHED':
                payload = len(pkt[Raw].load) if Raw in pkt else 0
                dss = None
                if mptcp:
                    sub = (mptcp[0] >> 4) & 0x0F
                    if sub == MPO_DSS:
                        dss = parse_dss(mptcp)
                st['client_seq'] = (tcp.seq + payload + (1 if fl & 0x01 else 0)) & 0xFFFFFFFF
                # The device's DataACK tells us its mpt_rcvnxt, i.e. the DSN it expects from us.
                if dss and dss[1] is not None:
                    st['dsn'] = dss[1] & 0xFFFFFFFF
                self.log(f"[*] data from {src_ip}:{sport} {payload}B dss={dss} "
                         f"client_seq->{st['client_seq']:#010x}")
                if self.triggered >= self.count:
                    self.log("[=] trigger budget reached, not sending DSS")
                    return
                self.send(server_ip, src_ip, self.port, sport, 'A', st['server_seq'], st['client_seq'], [])
                self.fire(server_ip, src_ip, sport, st)
                return

    def fire(self, server_ip, src_ip, sport, st):
        if self.mode == 'dfin':
            self.log("[!] mode 'dfin' is the panic path of the report; refusing to send")
            self.done = True
            return
        dss = dss_bad_csum_no_dfin(st['dsn'], st['dsn'], 1, dlen=1)
        seq = st['server_seq']
        self.log(f"[>>>] DSS dlen=1 DATA_FIN=0 csum=0xDEAD dsn={st['dsn']:#010x} sseq=1 "
                 f"tcp.seq={seq:#010x} ack={st['client_seq']:#010x} bytes={dss.hex()}")
        self.send(server_ip, src_ip, self.port, sport, 'PA', seq, st['client_seq'],
                  [(MPTCP_KIND, dss)], data=b'\xde')
        st['server_seq'] = (seq + 1) & 0xFFFFFFFF
        st['state'] = 'TRIGGERED'
        self.triggered += 1
        self.log("[>>>] waiting 2 s for the device's reply (MP_FAIL expected on the report's path)")
        if self.count and self.triggered >= self.count:
            time.sleep(2)
            self.done = True


def check_rst_filter(port: int) -> int:
    rc = subprocess.run(['iptables', '-S', 'OUTPUT'], capture_output=True, text=True)
    for line in rc.stdout.splitlines():
        if f"--sport {port}" in line and 'RST' in line and 'DROP' in line:
            print(f"RST filter present: {line}")
            return 0
    print(f"No outgoing-RST DROP rule for sport {port} in iptables OUTPUT. Without it the Linux "
          f"kernel answers RST to every SYN for that port and an XNU client cannot finish the handshake.")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iface', required=True)
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--mode', choices=['fail'], default='fail')
    ap.add_argument('--count', type=int, default=1, help='DSS segments to send in total')
    ap.add_argument('--server-key-hex')
    ap.add_argument('--pcap')
    ap.add_argument('--log')
    ap.add_argument('--check-rst-filter', action='store_true')
    ap.add_argument('--timeout', type=int, default=0, help='stop after N seconds (0 = until done)')
    a = ap.parse_args()

    if a.check_rst_filter:
        sys.exit(check_rst_filter(a.port))

    srv = Server(a)
    srv.log(f"mptcp_ip_server mode={a.mode} iface={a.iface} port={a.port} count={a.count} "
            f"server_key={srv.server_key:#018x}")
    if a.mode == 'fail':
        srv.log("Safe variant: DSS data_len=1, DATA_FIN=0, bad checksum. No spray, no FIN, no RST.")

    out = []
    try:
        sniff(iface=a.iface, filter=f"tcp port {a.port}", prn=lambda p: (out.append(p), srv.handle(p)),
              store=False, stop_filter=lambda p: srv.done, timeout=a.timeout or None)
    except KeyboardInterrupt:
        srv.log("interrupted")
    if a.pcap and out:
        from scapy.all import wrpcap
        wrpcap(a.pcap, out)
        srv.log(f"pcap: {a.pcap} ({len(out)} packets)")
    if a.log:
        with open(a.log, 'w') as f:
            f.write("\n".join(srv.log_lines) + "\n")


if __name__ == '__main__':
    main()
