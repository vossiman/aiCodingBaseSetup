import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'bin/leaniptv-diag'
PROD = 'FAKE-PROD-DIAG-TOKEN'
STAGING = 'FAKE-STAGING-DIAG-TOKEN'
UPLOAD = {'app_version': '0.1.2+1466', 'flavor': 'prod', 'device_model': 'Pixel 9 Pro',
          'events': [{'ts': 1, 'lvl': 'info', 'cmp': 'xtream', 'ev': 'provider_call', 'f': {'wait_ms': 3}}]}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get('Authorization')))
        if self.server.redirect:
            self.send_response(302)
            self.send_header('Location', 'https://example.invalid/steal')
            self.end_headers()
            return
        auth = self.headers.get('Authorization')
        env = {'Bearer ' + PROD: 'prod', 'Bearer ' + STAGING: 'staging'}.get(auth)
        if env is None:
            return self._json(401, {'error': 'unauthorized'})
        if self.path == '/v1/diagnostics/QMKG' and env in self.server.hits:
            return self._json(200, {'received_at': '2026-11-20T10:58:00+00:00', 'payload': UPLOAD})
        self._json(404, {'error': 'not_found'})

    def _json(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body)


class LeanIptvDiagTest(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.requests, self.server.redirect, self.server.hits = [], False, {'prod'}
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_helper(self, *args, prod=PROD, staging=STAGING):
        env = {k: v for k, v in os.environ.items() if not k.startswith('LEANIPTV_DIAG')}
        env['HOME'] = '/nonexistent'
        env['LEANIPTV_DIAG_TEST_URL'] = f'http://127.0.0.1:{self.server.server_port}'
        if prod is not None:
            env['LEANIPTV_DIAG_TEST_TOKEN_PROD'] = prod
        if staging is not None:
            env['LEANIPTV_DIAG_TEST_TOKEN_STAGING'] = staging
        r = subprocess.run(['python3', str(HELPER), *args], env=env, capture_output=True, text=True, timeout=30)
        for token in (PROD, STAGING):
            self.assertNotIn(token, r.stdout + r.stderr)
        return r

    def test_prints_the_hit_with_its_environment(self):
        r = self.run_helper(' qmkg ')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('== prod: received 2026-11-20T10:58:00+00:00', r.stdout)
        self.assertIn('"device_model": "Pixel 9 Pro"', r.stdout)
        self.assertIn('"wait_ms": 3', r.stdout)
        self.assertIn('== staging: no upload', r.stdout)

    def test_json_output(self):
        r = self.run_helper('QMKG', '--json')
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out['prod']['payload'], UPLOAD)
        self.assertEqual(out['staging'], {'status': 'no upload'})

    def test_no_hit_anywhere_exits_one(self):
        self.server.hits = set()
        r = self.run_helper('QMKG')
        self.assertEqual(r.returncode, 1)
        self.assertIn('== prod: no upload', r.stdout)

    def test_a_missing_token_is_reported_not_fatal(self):
        r = self.run_helper('QMKG', staging=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('== staging: not configured', r.stdout)

    def test_a_refused_token_names_the_environment(self):
        r = self.run_helper('QMKG', staging='WRONG-TOKEN')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('== staging: token refused (401)', r.stdout)

    def test_redirect_is_refused(self):
        self.server.redirect = True
        r = self.run_helper('QMKG')
        self.assertEqual(r.returncode, 2)
        self.assertIn('redirect refused', r.stdout)
        self.assertTrue(all('example.invalid' not in p for p, _ in self.server.requests))

    def test_an_invalid_code_is_refused_before_any_request(self):
        r = self.run_helper('../x')
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.server.requests, [])

    def test_test_url_must_be_loopback(self):
        env = dict(os.environ, HOME='/nonexistent', LEANIPTV_DIAG_TEST_URL='https://evil.invalid',
                   LEANIPTV_DIAG_TEST_TOKEN_PROD=PROD)
        r = subprocess.run(['python3', str(HELPER), 'QMKG'], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2)
        self.assertIn('loopback', r.stderr)


if __name__ == '__main__':
    unittest.main()
