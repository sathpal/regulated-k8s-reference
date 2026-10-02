"""patient-api: a minimal patient-record service built the way a healthcare platform needs it to behave.

- Access needs a role from the upstream gateway (X-User-Role); only clinicians read records.
- Every access, allowed or denied, is written to an audit log on stdout as JSON
  (HIPAA 164.312(b) audit controls). The log names who read which record, never the PHI itself.
- Responses are minimum necessary: a records clerk gets demographics only, never clinical notes.
- /readyz turns false on SIGTERM before the server stops, so Kubernetes drains traffic first.
- Standard library only: nothing to patch beyond the Python runtime itself.
"""
import json
import os
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("VERSION", "dev")

# Synthetic records only. Real PHI never belongs in an image, a ConfigMap or a test fixture.
RECORDS = {
    "p-1001": {"id": "p-1001", "name": "Asha Rao", "dob": "1984-03-12", "mrn": "MRN-55210",
               "allergies": ["penicillin"], "notes": "Type 2 diabetes, HbA1c 7.1 (synthetic)"},
    "p-1002": {"id": "p-1002", "name": "Daniel Moore", "dob": "1979-11-02", "mrn": "MRN-55211",
               "allergies": [], "notes": "Post-op follow-up, no complications (synthetic)"},
}
VIEWS = {  # minimum necessary: each role sees only the fields its job needs
    "clinician": ["id", "name", "dob", "mrn", "allergies", "notes"],
    "records-clerk": ["id", "name", "dob", "mrn"],
}

ready = threading.Event()


def audit(**fields):
    fields.update(time=datetime.now(timezone.utc).isoformat(), msg="audit", service="patient-api")
    print(json.dumps(fields), flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "patient-api"
    sys_version = ""

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")  # PHI must not sit in shared caches
        self.send_header("X-Request-Id", self.rid)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.rid = self.headers.get("X-Request-Id") or uuid.uuid4().hex[:16]
        if self.path == "/healthz":
            return self._send(200, b"ok\n", "text/plain")
        if self.path == "/readyz":
            return self._send(200 if ready.is_set() else 503, b"ready\n" if ready.is_set() else b"draining\n", "text/plain")
        if self.path == "/version":
            return self._send(200, {"service": "patient-api", "version": VERSION})
        if self.path.startswith("/v1/patients/"):
            pid = self.path.rsplit("/", 1)[-1]
            user, role = self.headers.get("X-User", ""), self.headers.get("X-User-Role", "")
            fields = VIEWS.get(role)
            if not user or fields is None:
                audit(request_id=self.rid, user=user or None, role=role or None, record=pid, outcome="denied")
                return self._send(403, {"error": "a known role is required"})
            rec = RECORDS.get(pid)
            audit(request_id=self.rid, user=user, role=role, record=pid, outcome="read" if rec else "not_found")
            if not rec:
                return self._send(404, {"error": "not found"})
            return self._send(200, {k: rec[k] for k in fields})
        self._send(404, {"error": "not found"})

    def log_message(self, *args):  # the audit line is the log; no raw access log with paths and IPs
        pass


def main():
    port = int(os.environ.get("PORT", "8080"))
    drain = float(os.environ.get("DRAIN_SECONDS", "5"))
    httpd = ThreadingHTTPServer(("", port), Handler)

    def on_term(signum, _frame):
        ready.clear()  # fail readiness first, let endpoints update, then stop
        print(json.dumps({"msg": "draining", "seconds": drain}), flush=True)
        threading.Thread(target=lambda: (time.sleep(drain), httpd.shutdown()), daemon=True).start()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    ready.set()
    print(json.dumps({"msg": "started", "version": VERSION, "port": port, "uid": os.getuid()}), flush=True)
    httpd.serve_forever()
    print(json.dumps({"msg": "stopped cleanly"}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
