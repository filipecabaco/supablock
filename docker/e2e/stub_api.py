#!/usr/bin/env python3
"""Minimal Supabase Management API stub for the Docker image e2e.

Serves just enough of the API (organizations, projects, health) for
`supablock ls` / `cat` and a FUSE mount to walk the tree. Fixtures mirror
test/support/fixtures.ex. Standard library only, so it runs anywhere the
CI runner has python3.

Usage: stub_api.py [port]     (default 54321, binds 127.0.0.1)
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORGS = [
    {"id": "org-alpha", "slug": "org-alpha", "name": "Alpha Org"},
    {"id": "org-beta", "slug": "org-beta", "name": "Beta Org"},
]

PROJECTS = [
    {
        "id": "projaone1234567890ab",
        "organization_id": "org-alpha",
        "name": "Alpha One",
        "region": "eu-west-1",
        "status": "ACTIVE_HEALTHY",
        "created_at": "2026-01-01T00:00:00Z",
    },
    {
        "id": "projbone1234567890ab",
        "organization_id": "org-beta",
        "name": "Beta One",
        "region": "ap-southeast-1",
        "status": "ACTIVE_HEALTHY",
        "created_at": "2026-03-01T00:00:00Z",
    },
]

HEALTH = [
    {"name": "auth", "healthy": True, "status": "ACTIVE_HEALTHY"},
    {"name": "db", "healthy": True, "status": "ACTIVE_HEALTHY"},
    {"name": "realtime", "healthy": False, "status": "UNHEALTHY"},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/v1/organizations":
            body = ORGS
        elif path == "/v1/projects":
            body = PROJECTS
        elif path.startswith("/v1/projects/") and path.endswith("/health"):
            body = HEALTH
        else:
            body = None

        if body is None:
            payload = json.dumps({"message": "not found"}).encode()
            self.send_response(404)
        else:
            payload = json.dumps(body).encode()
            self.send_response(200)

        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        sys.stderr.write("stub_api: %s\n" % (fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 54321
    print(f"stub_api: listening on 127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
