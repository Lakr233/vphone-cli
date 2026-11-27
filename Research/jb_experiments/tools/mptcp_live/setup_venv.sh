#!/bin/bash
# Create /root/jbresearch-mptcp/venv with scapy, without touching system python packages.
# Ubuntu's venv here has no pip and no ensurepip. Use the system pip if there is one (pointed at
# the venv interpreter); otherwise unpack the scapy wheel into the venv by hand.
set -e
D=/root/jbresearch-mptcp
mkdir -p "$D/logs" "$D/pcap"
cd "$D"
[ -x venv/bin/python ] || python3 -m venv venv
if command -v pip >/dev/null 2>&1; then
    pip --python "$D/venv/bin/python" install -q --disable-pip-version-check scapy
elif python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip --python "$D/venv/bin/python" install -q --disable-pip-version-check scapy
else
    URL=$(curl -sS -m 20 https://pypi.org/pypi/scapy/json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([u["url"] for u in d["urls"] if u["filename"].endswith(".whl")][0])')
    curl -sS -m 60 -o /tmp/scapy.whl "$URL"
    "$D/venv/bin/python" -m zipfile -e /tmp/scapy.whl "$D/venv/lib/python3.12/site-packages/"
    rm -f /tmp/scapy.whl
fi
"$D/venv/bin/python" -c 'import scapy; print("scapy", scapy.__version__)'
