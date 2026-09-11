#!/usr/bin/env python3
"""Tiny HTTP server for the web-watcher test suite.

GET  /<file>            serves <root>/<file> with a Content-Type derived from
                        its extension (json, html, txt, anything else = binary).
POST /...               records the request (path, content type, body) as a
                        JSON file in <logdir>, then answers 200 — or 400 when
                        the path contains "fail" (to simulate a webhook error).

Usage: server.py <root> <logdir>
The chosen port is printed on stdout once the server is listening.
"""
import json
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class FastHTTPServer(HTTPServer):
    """HTTPServer without the reverse-DNS lookup done at bind time.

    HTTPServer.server_bind calls socket.getfqdn(), which blocks for several
    seconds on hosts with no reverse DNS (CI runners), long enough for the
    test suite to give up waiting for the port.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]

ROOT = sys.argv[1]
LOGDIR = sys.argv[2]
CONTENT_TYPES = {
    "json": "application/json",
    "html": "text/html; charset=utf-8",
    "txt": "text/plain; charset=utf-8",
}


class Handler(BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, *args):  # keep the test output clean
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        target = os.path.join(ROOT, path.lstrip("/"))
        if not os.path.isfile(target):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(target, "rb") as fh:
            data = fh.read()
        ext = target.rsplit(".", 1)[-1]
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPES.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        Handler.counter += 1
        record = {
            "path": self.path,
            "content_type": self.headers.get("Content-Type", ""),
            "body": body.decode("utf-8", "replace"),
        }
        with open(os.path.join(LOGDIR, "%03d.json" % Handler.counter), "w") as fh:
            json.dump(record, fh)
        status = 400 if "fail" in self.path else 200
        self.send_response(status)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


def main():
    server = FastHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
