#!/usr/bin/env python3
"""
Developer Workspaces portal — Python web app + stub API.

* Standard library only (http.server), so it runs from the plain python:3.12-slim image with no network access.
* Serves index.html at / and a JSON API under /api/.  Every API function below returns STATIC data for now;
  replace the bodies with real calls (kubectl/helm/Kubernetes API) later without touching the routing or the page.
* Identity comes from oauth2-proxy, which sits in front of this app and sets X-Forwarded-User / -Email /
  -Preferred-Username / -Groups after the Keycloak login.  Requests without those headers get 401 on /api.

Environment: PORT (8080), WEB_ROOT (dir with index.html), NAMESPACE_PREFIX (ws-), REQUIRE_AUTH (1),
             ADMIN_GROUP (admins), LOGOUT_URL (where "Sign out" goes).
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8080"))
WEB_ROOT = os.environ.get("WEB_ROOT", os.path.dirname(os.path.abspath(__file__)))
NS_PREFIX = os.environ.get("NAMESPACE_PREFIX", "ws-")
REQUIRE_AUTH = os.environ.get("REQUIRE_AUTH", "1") == "1"
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "admins")
LOGOUT_URL = os.environ.get("LOGOUT_URL", "/oauth2/sign_out")
STARTED = time.time()

def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")

# --------------------------------------------------------------------------------------------- identity
class Identity:
    """What oauth2-proxy tells us about the caller."""
    def __init__(self, headers):
        self.user = headers.get("X-Forwarded-Preferred-Username") or headers.get("X-Forwarded-User") or ""
        self.email = headers.get("X-Forwarded-Email") or ""
        groups = headers.get("X-Forwarded-Groups") or ""
        self.groups = [g.strip().lstrip("/") for g in groups.split(",") if g.strip()]
        self.authenticated = bool(self.user or self.email)

    @property
    def is_admin(self):
        return ADMIN_GROUP in self.groups

    def as_dict(self):
        return {
            "user": self.user, "email": self.email, "groups": self.groups, "isAdmin": self.is_admin,
            "namespace": NS_PREFIX + re.sub(r"[^a-z0-9-]", "-", (self.user or "anon").lower())[:40],
            "logoutUrl": LOGOUT_URL,
        }

# --------------------------------------------------------------------------------------------- static data
CATALOG = {
    "languages": {
        "go":     {"label": "Go",       "cmd": "go",      "ver": "go version go1.25.3 linux/amd64"},
        "python": {"label": "Python",   "cmd": "python3", "ver": "Python 3.12.3"},
        "rust":   {"label": "Rust",     "cmd": "cargo",   "ver": "cargo 1.90.0"},
        "node":   {"label": "Node.js",  "cmd": "node",    "ver": "v22.20.0"},
        "java":   {"label": "Java",     "cmd": "java",    "ver": "openjdk 21.0.4 2024-07-16"},
        "cpp":    {"label": "C / C++",  "cmd": "gcc",     "ver": "gcc (Ubuntu 13.3.0) 13.3.0"},
    },
    "tools": {
        "cmake":   {"cmd": "cmake",       "ver": "cmake version 3.28.3",   "src": "image",       "desc": "CMake + Ninja"},
        "gdb":     {"cmd": "gdb",         "ver": "GNU gdb 15.0.50",        "src": "image",       "desc": "gdb, lldb, strace, valgrind"},
        "kubectl": {"cmd": "kubectl",     "ver": "Client Version: v1.36.4","src": "image",       "desc": "kubectl + helm"},
        "ripgrep": {"cmd": "rg",          "ver": "ripgrep 14.1.1",         "src": "artifactory", "desc": "fast text search"},
        "fd":      {"cmd": "fd",          "ver": "fd 10.2.0",              "src": "artifactory", "desc": "friendly find"},
        "gh":      {"cmd": "gh",          "ver": "gh version 2.74.0",      "src": "artifactory", "desc": "GitHub CLI"},
        "k9s":     {"cmd": "k9s",         "ver": "Version: v0.50.6",       "src": "artifactory", "desc": "terminal UI for Kubernetes"},
        "mcast":   {"cmd": "mcast-check", "ver": "mcast-check (python)",   "src": "image",       "desc": "multicast test kit"},
    },
    "sizes": {
        "small":  {"cpu": "2", "mem": "4Gi",  "disk": "20Gi"},
        "medium": {"cpu": "4", "mem": "8Gi",  "disk": "30Gi"},
        "large":  {"cpu": "8", "mem": "16Gi", "disk": "50Gi"},
    },
    "profiles": ["standard", "hardware"],
    "idleMinutes": 240,
}

SAMPLE_WORKSPACES = [
    {"name": "engine", "languages": ["go", "python"], "tools": ["ripgrep", "cmake"], "size": "medium", "profile": "standard",
     "multicast": False, "idle": 240, "status": "Running", "pod": "ws-engine-0", "node": "aks-default-vm000001",
     "repo": "git@github.com:acme/engine.git", "createdAt": "2026-11-10T14:02:00Z", "lastActive": now_iso()},
    {"name": "lab-fpga", "languages": ["cpp"], "tools": ["gdb"], "size": "large", "profile": "hardware",
     "multicast": True, "idle": 480, "status": "Stopped", "pod": None, "node": None,
     "repo": "", "createdAt": "2026-11-12T09:30:00Z", "lastActive": "2026-11-14T18:11:00Z"},
]

SAMPLE_EVENTS = [
    {"t": now_iso(), "kind": "info", "msg": "portal API started (stub mode: all data is static)", "ws": None},
    {"t": "2026-11-14T18:11:00Z", "kind": "info", "msg": "lab-fpga stopped — idle for 480 min (reaper)", "ws": "lab-fpga"},
    {"t": "2026-11-10T14:03:10Z", "kind": "ok", "msg": "engine is Running on aks-default-vm000001", "ws": "engine"},
]

# --------------------------------------------------------------------------------------------- API functions
# Each function: (identity, path_params: dict, query: dict, body: dict|None) -> (status, json)
# Add a function + one ROUTES entry and the page's "API" tab picks it up automatically via /api.

def _friendly(pat):
    """'^/api/workspaces/(?P<name>[a-z0-9-]+)/logs$' -> ('/api/workspaces/{name}/logs', '/api/workspaces/engine/logs')"""
    shown = re.sub(r"\(\?P<(\w+)>[^)]*\)", r"{\1}", pat).strip("^$").replace("/?", "")
    example = shown.replace("{name}", "engine").replace("{action}", "start")
    return shown, example

def api_index(me, p, q, body):
    """This list: every API function, its method, path and an example URL."""
    fns = []
    for (m, pat, auth), fn in ROUTES:
        shown, example = _friendly(pat)
        fns.append({"method": m, "path": shown, "example": example, "auth": auth, "doc": (fn.__doc__ or "").strip()})
    return 200, {"service": "developer-workspaces-api", "mode": "stub", "uptimeSeconds": int(time.time() - STARTED), "functions": fns}

def api_me(me, p, q, body):
    """Who is logged in (from oauth2-proxy headers): user, e-mail, groups, admin flag, namespace."""
    return 200, me.as_dict()

def api_health(me, p, q, body):
    """Liveness/readiness. Never requires auth."""
    return 200, {"ok": True, "time": now_iso()}

def api_catalog(me, p, q, body):
    """Languages, tools, sizes and profiles a workspace can be created from."""
    cat = dict(CATALOG)
    if not me.is_admin:
        cat = {**cat, "profiles": ["standard"], "note": f"the 'hardware' profile needs group '{ADMIN_GROUP}'"}
    return 200, cat

def api_workspaces(me, p, q, body):
    """List the caller's workspaces (static sample until the Kubernetes backend exists)."""
    return 200, {"namespace": me.as_dict()["namespace"], "items": SAMPLE_WORKSPACES}

def api_workspace_get(me, p, q, body):
    """One workspace by name."""
    for w in SAMPLE_WORKSPACES:
        if w["name"] == p["name"]:
            return 200, w
    return 404, {"error": f"workspace {p['name']} not found"}

def api_workspace_create(me, p, q, body):
    """Create a workspace. Validates the request shape and echoes what WOULD be created."""
    body = body or {}
    name = str(body.get("name", "")).strip()
    if not re.match(r"^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$", name):
        return 400, {"error": "name must be lowercase letters, digits and dashes (max 40)"}
    langs = [l for l in body.get("languages", []) if l in CATALOG["languages"]]
    if not langs:
        return 400, {"error": "pick at least one language from the catalog"}
    if body.get("profile") == "hardware" and not me.is_admin:
        return 403, {"error": f"profile 'hardware' requires group '{ADMIN_GROUP}'", "yourGroups": me.groups}
    size = body.get("size", "medium") if body.get("size") in CATALOG["sizes"] else "medium"
    return 202, {"accepted": True, "stub": True, "name": name, "owner": me.user, "namespace": me.as_dict()["namespace"],
                 "image": f"workspace/workspace-{langs[0]}:dev", "languages": langs,
                 "tools": [t for t in body.get("tools", []) if t in CATALOG["tools"]], "size": size,
                 "profile": body.get("profile", "standard"), "status": "Pending",
                 "message": "stub: nothing was created; the real implementation will run helm upgrade --install here"}

def api_workspace_action(me, p, q, body):
    """start | stop | delete a workspace (stub acknowledgement)."""
    action = p["action"]
    if action not in ("start", "stop", "delete"):
        return 404, {"error": f"unknown action {action}"}
    return 202, {"accepted": True, "stub": True, "name": p["name"], "action": action, "by": me.user,
                 "command": {"start": f"kubectl scale statefulset ws-{p['name']} --replicas=1",
                             "stop": f"kubectl scale statefulset ws-{p['name']} --replicas=0",
                             "delete": f"helm uninstall ws-{p['name']}" + (" + delete pvc" if q.get("purge") == ["true"] else "")}[action]}

def api_workspace_logs(me, p, q, body):
    """Boot log lines of a workspace."""
    return 200, {"name": p["name"], "lines": [
        f"[workspace] workspace '{p['name']}' starting: lang=go profile=standard tools=ripgrep,cmake",
        "[workspace] first boot: seeding /home/dev from /opt/workspace/skel",
        "[workspace] sshd listening on 127.0.0.1:2222 (pid 42)",
        "[workspace] installing artifact tool: ripgrep  (download: https://artifactory.example.com/…)",
        "[workspace] tool ready: ripgrep", "[workspace] ready"]}

def api_events(me, p, q, body):
    """Recent events, newest first."""
    return 200, {"items": SAMPLE_EVENTS}

def api_groups(me, p, q, body):
    """Groups known to the portal and what they unlock."""
    return 200, {"groups": {
        "developers": {"description": "may create standard workspaces", "members": ["demo", "dev2"]},
        ADMIN_GROUP:  {"description": "may use the hardware profile and see everyone's workspaces", "members": ["demo"]}},
        "yourGroups": me.groups}

def api_admin_all(me, p, q, body):
    """(admins only) every workspace in the cluster."""
    if not me.is_admin:
        return 403, {"error": f"requires group '{ADMIN_GROUP}'", "yourGroups": me.groups}
    return 200, {"items": SAMPLE_WORKSPACES + [{"name": "ci-runner", "owner": "svc-ci", "status": "Running", "size": "large"}]}

ROUTES = [
    (("GET",    r"^/api/?$",                                        False), api_index),
    (("GET",    r"^/api/health$",                                   False), api_health),
    (("GET",    r"^/api/me$",                                       True),  api_me),
    (("GET",    r"^/api/catalog$",                                  True),  api_catalog),
    (("GET",    r"^/api/groups$",                                   True),  api_groups),
    (("GET",    r"^/api/events$",                                   True),  api_events),
    (("GET",    r"^/api/workspaces$",                               True),  api_workspaces),
    (("POST",   r"^/api/workspaces$",                               True),  api_workspace_create),
    (("GET",    r"^/api/workspaces/(?P<name>[a-z0-9-]+)$",          True),  api_workspace_get),
    (("GET",    r"^/api/workspaces/(?P<name>[a-z0-9-]+)/logs$",     True),  api_workspace_logs),
    (("POST",   r"^/api/workspaces/(?P<name>[a-z0-9-]+)/(?P<action>start|stop|delete)$", True), api_workspace_action),
    (("DELETE", r"^/api/workspaces/(?P<name>[a-z0-9-]+)$",          True),  lambda me, p, q, b: api_workspace_action(me, {**p, "action": "delete"}, q, b)),
    (("GET",    r"^/api/admin/workspaces$",                         True),  api_admin_all),
]
ROUTES = [((m, pat, auth), fn) for (m, pat, auth), fn in ROUTES]
_COMPILED = [((m, re.compile(pat), auth), fn) for (m, pat, auth), fn in ROUTES]

# --------------------------------------------------------------------------------------------- HTTP handler
class Handler(BaseHTTPRequestHandler):
    server_version = "devws-portal/1.0"

    def log_message(self, fmt, *args):   # one JSON line per request (goes to kubectl logs)
        me = Identity(self.headers)
        sys.stdout.write(json.dumps({"ts": now_iso(), "method": self.command, "path": self.path,
                                     "user": me.user or None, "groups": me.groups, "msg": fmt % args}) + "\n")
        sys.stdout.flush()

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=()):
        data = body if isinstance(body, bytes) else json.dumps(body, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Served-By", os.environ.get("HOSTNAME", "local"))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _dispatch(self):
        url = urlparse(self.path)
        me = Identity(self.headers)
        if url.path.startswith("/api"):
            for (method, rx, needs_auth), fn in _COMPILED:
                m = rx.match(url.path)
                if m and method == self.command:
                    if needs_auth and REQUIRE_AUTH and not me.authenticated:
                        return self._send(401, {"error": "not authenticated: no identity headers from oauth2-proxy"})
                    body = None
                    if self.command in ("POST", "PUT", "PATCH"):
                        n = int(self.headers.get("Content-Length") or 0)
                        raw = self.rfile.read(n) if n else b""
                        try:
                            body = json.loads(raw or b"{}")
                        except ValueError:
                            return self._send(400, {"error": "body must be JSON"})
                    code, payload = fn(me, m.groupdict(), parse_qs(url.query), body)
                    return self._send(code, payload)
            return self._send(404, {"error": f"no API function for {self.command} {url.path}",
                                    "functions": [f"{m} {_friendly(p)[0]}" for (m, p, _), _ in ROUTES]})
        if url.path == "/healthz":
            return self._send(200, b"ok", "text/plain")
        if url.path == "/logout":
            return self._send(302, b"", "text/plain", [("Location", LOGOUT_URL)])
        if url.path in ("/", "/index.html"):
            if REQUIRE_AUTH and not me.authenticated:
                return self._send(401, b"<h1>401</h1><p>No identity headers. This app must be reached through oauth2-proxy.</p>", "text/html")
            with open(os.path.join(WEB_ROOT, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        return self._send(404, {"error": "not found"})

    def do_GET(self):    self._dispatch()
    def do_POST(self):   self._dispatch()
    def do_DELETE(self): self._dispatch()
    def do_HEAD(self):   self._dispatch()

if __name__ == "__main__":
    print(json.dumps({"ts": now_iso(), "msg": f"portal listening on :{PORT}", "webRoot": WEB_ROOT, "requireAuth": REQUIRE_AUTH,
                      "functions": len(ROUTES)}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
