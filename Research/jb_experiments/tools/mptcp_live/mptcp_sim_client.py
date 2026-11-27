#!/usr/bin/env python3
"""
mptcp_sim_client.py — raw XNU-like client used only to test mptcp_ip_server.py between two Linux hosts.
It is NOT a faithful XNU: it keeps going on a fixed schedule even if the server kernel sends an RST,
so the server's replies can be asserted packet by packet without an outgoing-RST filter on the server.
That difference is exactly why a real XNU client needs that filter and this one does not.

Sends: SYN [MP_CAPABLE v1], 3rd ACK [MP_CAPABLE with both keys], PSH+ACK with one byte and a DSS.
usage: mptcp_sim_client.py --iface IF --src IP --dst IP --port N --server-key-hex HEX
"""
import argparse, hashlib, struct, time, threading
from scapy.all import IP, TCP, Raw, L3RawSocket
from scapy.sendrecv import AsyncSniffer as AsyncSniff

KIND = 30

def ids(key):
    return struct.unpack('>Q', hashlib.sha256(struct.pack('!Q', key)).digest()[24:32])[0]

ap = argparse.ArgumentParser()
ap.add_argument('--iface', required=True)
ap.add_argument('--src', required=True)
ap.add_argument('--dst', required=True)
ap.add_argument('--port', type=int, required=True)
ap.add_argument('--server-key-hex', required=True)
ap.add_argument('--sport', type=int, default=0)
a = ap.parse_args()
sport = a.sport or (int(time.time() * 1000) % 20000 + 40000)
skey = int(a.server_key_hex, 16)
ckey = 0x1122334455667788
cidsn = (ids(ckey) + 1) & 0xFFFFFFFF
sdsn = (ids(skey) + 1) & 0xFFFFFFFF
cseq = 0x22222222
sock = L3RawSocket(iface=a.iface)
lock = threading.Lock()
synack_seq = None
server_data_seq = None
got = {'synack': 0, 'rst': 0, 'data': 0}


def rx(p):
    global synack_seq, server_data_seq
    if IP not in p or TCP not in p or p[TCP].sport != a.port or p[TCP].dport != sport:
        return
    f = int(p[TCP].flags)
    o = [bytes(v) for k, v in p[TCP].options if k == KIND]
    m = o[0] if o else b''
    plen = len(p[Raw].load) if Raw in p else 0
    print(f"  <- fl={f:#04x} seq={p[TCP].seq:#010x} ack={p[TCP].ack:#010x} mptcp={m.hex() or '-'} plen={plen}",
          flush=True)
    with lock:
        if f & 0x12 == 0x12:
            got['synack'] += 1
            synack_seq = p[TCP].seq
        elif f & 0x04:
            got['rst'] += 1
        if f & 0x18 == 0x18 and plen:
            got['data'] += 1
            server_data_seq = p[TCP].seq


ready = threading.Event()
def _sniff():
    # AsyncSniff opens the capture socket before it returns, so the sniffer is live before the SYN leaves.
    global _as
    _as = AsyncSniff(iface=a.iface, filter=f"tcp port {a.port}", prn=rx, store=False)
    _as.start()
    ready.set()
threading.Thread(target=_sniff, daemon=True).start()
ready.wait(5)
time.sleep(0.8)  # let the BPF attach


def tx(flags, seq, ack, opts=(), data=b''):
    p = IP(src=a.src, dst=a.dst) / TCP(sport=sport, dport=a.port, flags=flags, seq=seq, ack=ack,
                                       window=65535, options=list(opts))
    if data:
        p = p / Raw(load=data)
    sock.send(p)


mpc_v1 = bytes([0x11, 0x01])                                   # subtype 0 | version 1; scapy adds kind+len
mpc_ack = bytes([0x11, 0x81]) + struct.pack('!QQ', ckey, skey)  # both keys; A bit echoes the server's checksum request
dss = bytes([0x20, 0x05]) + struct.pack('!IIIHH', sdsn, cidsn, 0, 1, 0)  # A|M, DataACK, DSN, sseq=0, dlen=1, csum
print(f"client {a.src}:{sport} -> {a.dst}:{a.port} client_key={ckey:#018x} "
      f"data_ack={sdsn:#010x} dsn={cidsn:#010x}")
tx('S', cseq, 0, [(KIND, mpc_v1)])
time.sleep(1.2)
with lock:
    s = synack_seq
if s is None:
    print("no SYN-ACK captured (server not reachable)")
    raise SystemExit(1)
tx('A', cseq + 1, (s + 1) & 0xFFFFFFFF, [(KIND, mpc_ack)])
time.sleep(0.6)
tx('PA', cseq + 1, (s + 1) & 0xFFFFFFFF, [(KIND, dss)], data=b'A')
time.sleep(3.0)
try:
    _as.stop(stop_cb=True)
except Exception:
    pass
print(f"summary: synack={got['synack']} kernel_rst={got['rst']} server_data_segments={got['data']} "
      f"server_next_seq={server_data_seq and hex(server_data_seq)}")
