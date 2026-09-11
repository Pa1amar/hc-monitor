#!/usr/bin/env python3
"""Fake healthchecks.io endpoint for the tests.

Every request appends a "METHOD PATH" line to <dir>/requests.log and stores
its body in <dir>/body.txt. The response code comes from <dir>/status
(200 by default). The chosen port is written to <dir>/port.
"""
import http.server
import os
import sys

DIR = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        with open(os.path.join(DIR, "requests.log"), "a") as log:
            log.write(f"{self.command} {self.path}\n")
        with open(os.path.join(DIR, "body.txt"), "wb") as out:
            out.write(body)
        try:
            with open(os.path.join(DIR, "status")) as status_file:
                status = int(status_file.read().strip())
        except FileNotFoundError:
            status = 200
        self.send_response(status)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    do_GET = do_POST

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as port_file:
    port_file.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
