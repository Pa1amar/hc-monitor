#!/usr/bin/env python3
"""TLS endpoints for the certificate tests.

For every name given after <dir>, serves <dir>/<name>.pem with <dir>/<name>.key on its own
port on 127.0.0.1, then writes "name port" lines to <dir>/ports.
"""
import os
import socket
import ssl
import sys
import threading

DIR = sys.argv[1]


def serve(sock, context):
    while True:
        conn, _ = sock.accept()
        try:
            context.wrap_socket(conn, server_side=True).close()
        except (ssl.SSLError, OSError):
            conn.close()


lines = []
for name in sys.argv[2:]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(DIR, name + ".pem"), os.path.join(DIR, name + ".key"))
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(16)
    lines.append(f"{name} {sock.getsockname()[1]}\n")
    threading.Thread(target=serve, args=(sock, context), daemon=True).start()

with open(os.path.join(DIR, "ports.tmp"), "w") as out:
    out.writelines(lines)
os.replace(os.path.join(DIR, "ports.tmp"), os.path.join(DIR, "ports"))
threading.Event().wait()
