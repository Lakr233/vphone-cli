#!/usr/bin/env python3
"""Minimal fake TSS server — serves a cached SHSH blob as a TSS response.

Usage: tss_server.py <port> <shsh_file>

idevicerestore POSTs a TSS request to this server. We ignore the request body
and return a plist dict containing the pre-downloaded ApImg4Ticket. This lets
idevicerestore run fully offline without contacting Apple's TSS servers.
"""
import gzip
import plistlib
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def load_ticket(shsh_path):
    with gzip.open(shsh_path, "rb") as f:
        pl = plistlib.load(f)
    return bytes(pl["ApImg4Ticket"])


class TSSHandler(BaseHTTPRequestHandler):
    ticket = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        plist_xml = plistlib.dumps({"ApImg4Ticket": self.ticket}, fmt=plistlib.FMT_XML)
        # libtatsu expects: STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=<?xml ...>
        body = b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=" + plist_xml
        self.send_response(200)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <port> <shsh_file>", file=sys.stderr)
        sys.exit(1)
    port = int(sys.argv[1])
    TSSHandler.ticket = load_ticket(sys.argv[2])
    HTTPServer(("127.0.0.1", port), TSSHandler).serve_forever()
