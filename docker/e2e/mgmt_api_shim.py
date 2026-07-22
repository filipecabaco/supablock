#!/usr/bin/env python3
"""Thin Management API shim for the Docker image e2e.

The supabase CLI's local stack (`supabase start`) emulates a real *project*
— Postgres, PostgREST, working API keys — but the platform Management API
(organization/project metadata) exists only at api.supabase.com and has no
local emulator. This shim serves just that thin metadata layer and points
supablock at the real local stack: its api-keys endpoint returns the
stack's actual anon/service_role JWTs (passed in via the ANON_KEY and
SERVICE_ROLE_KEY environment variables, from `supabase status -o env`), so
the `database/` tree reads real seeded rows through the real PostgREST.

The health endpoint is synthesized — the local stack exposes no
Management-API-shaped health resource.

Usage: ANON_KEY=... SERVICE_ROLE_KEY=... mgmt_api_shim.py [port]
       (default port 54340, binds 127.0.0.1)
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REF = "supablocklocal123456"

ORGS = [{"id": "org-local", "slug": "org-local", "name": "Local Org"}]

PROJECTS = [
    {
        "id": REF,
        "organization_id": "org-local",
        "name": "Local Project (supabase start)",
        "region": "local",
        "status": "ACTIVE_HEALTHY",
        "created_at": "2026-01-01T00:00:00Z",
    }
]

HEALTH = [
    {"name": "db", "healthy": True, "status": "ACTIVE_HEALTHY"},
    {"name": "rest", "healthy": True, "status": "ACTIVE_HEALTHY"},
]

# Exposed schemas drive the database/ tree: naming `app` next to `public`
# here is what makes supablock list both (config.toml adds `app` to the
# local PostgREST's schemas so the reads actually work).
POSTGREST = {
    "db_schema": "public, app",
    "max_rows": 1000,
    "db_extra_search_path": "public, extensions",
}

# database/{backups,migrations,readonly}.json render these endpoints as
# files. A FUSE mount stats every entry a readdir returns, so they must
# answer 200 — a 404 turns into ENOENT and breaks plain `ls` of database/.
BACKUPS = {"region": "local", "pitr_enabled": False, "walg_enabled": False, "backups": []}

MIGRATIONS = [{"version": "20260101000000", "name": "e2e"}]

READONLY = {"enabled": False, "override_enabled": False}


def api_keys():
    return [
        {"name": "anon", "api_key": os.environ["ANON_KEY"]},
        {"name": "service_role", "api_key": os.environ["SERVICE_ROLE_KEY"]},
    ]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/v1/organizations":
            body = ORGS
        elif path == "/v1/projects":
            body = PROJECTS
        elif path == f"/v1/projects/{REF}/health":
            body = HEALTH
        elif path == f"/v1/projects/{REF}/api-keys":
            body = api_keys()
        elif path == f"/v1/projects/{REF}/postgrest":
            body = POSTGREST
        elif path == f"/v1/projects/{REF}/database/backups":
            body = BACKUPS
        elif path == f"/v1/projects/{REF}/database/migrations":
            body = MIGRATIONS
        elif path == f"/v1/projects/{REF}/readonly":
            body = READONLY
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
        sys.stderr.write("mgmt_api_shim: %s\n" % (fmt % args))


if __name__ == "__main__":
    for var in ("ANON_KEY", "SERVICE_ROLE_KEY"):
        if not os.environ.get(var):
            sys.exit(f"mgmt_api_shim: {var} must be set (see: supabase status -o env)")

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 54340
    print(f"mgmt_api_shim: serving ref {REF} on 127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
