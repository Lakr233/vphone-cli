# Does the kernel answer a SYN to a port without a listener with an RST (visible on the wire)?
# usage: probe_rst.py <iface>   -- sniffs tcp/9999 for 8 s.
import sys
from scapy.all import sniff, IP, TCP
IFACE = sys.argv[1]
PORT = 9999
def h(p):
    if IP in p and TCP in p:
        f = int(p[TCP].flags)
        print(f"  {p[IP].src}:{p[TCP].sport} -> {p[IP].dst}:{p[TCP].dport} fl={f:#04x} seq={p[TCP].seq:#010x} ack={p[TCP].ack:#010x}", flush=True)
sniff(iface=IFACE, filter=f"tcp port {PORT}", prn=h, store=False, timeout=8)
