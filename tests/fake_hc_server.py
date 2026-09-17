#!/usr/bin/env python3
"""Fake healthchecks.io endpoint (and health check target) for the tests.

Every request appends a "METHOD PATH" line to <dir>/requests.log and stores its
body in <dir>/body.txt and in <dir>/bodies/<key>, where <key> is the path with
"/" replaced by "_". The answer's status comes from <dir>/status<key>, then
<dir>/status (200 by default); its body from <dir>/response<key> ("OK" by
default). The chosen port is written to <dir>/port.
"""
import http.server
import os
import sys

DIR = sys.argv[1]


def read(name):
    try:
        with open(os.path.join(DIR, name)) as file:
            return file.read()
    except FileNotFoundError:
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        key = self.path.replace("/", "_")
        with open(os.path.join(DIR, "requests.log"), "a") as log:
            log.write(f"{self.command} {self.path}\n")
        with open(os.path.join(DIR, "body.txt"), "wb") as out:
            out.write(body)
        os.makedirs(os.path.join(DIR, "bodies"), exist_ok=True)
        with open(os.path.join(DIR, "bodies", key), "wb") as out:
            out.write(body)
        status = read(f"status{key}") or read("status") or "200"
        response = read(f"response{key}")
        response = (response if response is not None else "OK").encode()
        self.send_response(int(status.strip()))
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    do_GET = do_POST

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as port_file:
    port_file.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
