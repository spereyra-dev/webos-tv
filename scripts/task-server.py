#!/usr/bin/env python3
"""Tiny one-purpose HTTP channel used by webos-tv.sh.

GET  /<file>  serves a file from ./serve (the task script and any payload blob)
POST /result  stores the body in ./result, which the shell then prints

Nothing listens longer than one command: webos-tv.sh starts this, runs slopbro, waits
for the result, and kills it. No authentication on purpose — it only ever exists for a
few seconds on the local LAN and serves one throwaway script. Do not run it anywhere
the TV cannot be, and do not leave it up.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
SERVE = os.path.join(ROOT, "serve")
RESULT = os.path.join(ROOT, "result")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        name = os.path.basename(self.path or "")
        path = os.path.join(SERVE, name)
        if name and os.path.isfile(path):
            data = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        with open(RESULT, "wb") as fh:
            fh.write(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):  # keep the console for the tool's own output
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
