#!/usr/bin/env python3
"""Serve overlord's static status site read only, behind HTTP Basic auth.

GET and HEAD only; no directory listings; never serves dotfiles or anything
outside the site directory. Login from OVERLORD_WEB_USER / OVERLORD_WEB_PASS.
"""
import base64
import hmac
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

SITE = os.environ.get("OVERLORD_SITE", os.path.expanduser("~/site"))
PORT = int(os.environ.get("OVERLORD_WEB_PORT", "8090"))
USER = os.environ.get("OVERLORD_WEB_USER", "").encode()
PASS = os.environ.get("OVERLORD_WEB_PASS", "").encode()
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript",
         ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml", ".txt": "text/plain; charset=utf-8"}


class Handler(BaseHTTPRequestHandler):
    server_version = "overlord"
    sys_version = ""

    def authorized(self):
        h = self.headers.get("Authorization", "")
        try:
            user, _, pw = base64.b64decode(h[6:], validate=True).partition(b":") if h.startswith("Basic ") else (b"", "", b"")
        except ValueError:
            user, pw = b"", b""
        ok_user = hmac.compare_digest(user, USER)
        ok_pass = hmac.compare_digest(pw, PASS)
        return ok_user and ok_pass

    def resolve(self):
        parts = [p for p in unquote(urlsplit(self.path).path).split("/") if p]
        if any(p.startswith(".") or "\\" in p or "\0" in p for p in parts):
            return None
        base = os.path.realpath(SITE)
        path = os.path.realpath(os.path.join(base, *parts))
        if path != base and not path.startswith(base + os.sep):
            return None
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        return path if os.path.isfile(path) else None

    def send(self, code, body, ctype="text/plain; charset=utf-8", head=False, extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def do_GET(self, head=False):
        if not self.authorized():
            return self.send(401, b"login required\n", head=head, extra=[("WWW-Authenticate", 'Basic realm="overlord"')])
        path = self.resolve()
        if path is None:
            return self.send(404, b"not found\n", head=head)
        with open(path, "rb") as f:
            body = f.read()
        self.send(200, body, TYPES.get(os.path.splitext(path)[1], "application/octet-stream"), head)

    def do_HEAD(self):
        self.do_GET(head=True)


if __name__ == "__main__":
    if not USER or not PASS:
        sys.exit("overlord_web: OVERLORD_WEB_USER and OVERLORD_WEB_PASS must be set")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
