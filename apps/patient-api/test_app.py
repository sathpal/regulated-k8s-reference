import contextlib
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import app


class PatientApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        app.ready.set()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def get(self, path, **headers):
        req = urllib.request.Request(self.base + path, headers=headers)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            try:
                with urllib.request.urlopen(req) as r:
                    return r.status, json.loads(r.read() or b"{}"), out.getvalue()
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read() or b"{}"), out.getvalue()

    def test_no_role_is_denied_and_audited(self):
        code, _, log = self.get("/v1/patients/p-1001")
        self.assertEqual(code, 403)
        self.assertIn('"outcome": "denied"', log)

    def test_clinician_sees_clinical_fields(self):
        code, body, _ = self.get("/v1/patients/p-1001", **{"X-User": "dr.mehta", "X-User-Role": "clinician"})
        self.assertEqual(code, 200)
        self.assertIn("notes", body)

    def test_clerk_gets_minimum_necessary(self):
        code, body, _ = self.get("/v1/patients/p-1001", **{"X-User": "clerk.ana", "X-User-Role": "records-clerk"})
        self.assertEqual(code, 200)
        self.assertNotIn("notes", body)
        self.assertNotIn("allergies", body)

    def test_audit_never_contains_phi(self):
        _, _, log = self.get("/v1/patients/p-1001", **{"X-User": "dr.mehta", "X-User-Role": "clinician"})
        self.assertIn('"record": "p-1001"', log)
        for phi in ("Asha Rao", "1984-03-12", "MRN-55210", "diabetes"):
            self.assertNotIn(phi, log)

    def test_readiness_follows_drain(self):
        app.ready.clear()
        try:
            req = urllib.request.Request(self.base + "/readyz")
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req)
            self.assertEqual(cm.exception.code, 503)
        finally:
            app.ready.set()


if __name__ == "__main__":
    unittest.main()
