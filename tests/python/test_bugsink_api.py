import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'bin/bugsink-api'
TOKEN = 'FAKE-BUGSINK-AUTH-TOKEN'
KEY = 'FAKE-INGESTION-KEY'


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
        if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
            self.send_error(401)
            return
        base = f'http://127.0.0.1:{self.server.server_port}'
        project = dict(id=1, name='Smoke project', dsn=f'http://{KEY}@127.0.0.1:{self.server.server_port}/1')
        if self.server.bad_dsn:
            project['dsn'] = 'https://private-key@evil.invalid/1'
        issue = dict(id='abc', project=1, calculated_type='SmokeError',
                     calculated_value=f'password=hidden Authorization: Bearer {TOKEN} Request body: {{"password": "FAKE-PASSWORD"}} api-key=FAKE-KEY Basic RkFLRTpQQVNT',
                     title=f'Problem at http://{KEY}@127.0.0.1/1')
        if '/projects/1/' in self.path:
            value = project
        elif '/projects/' in self.path:
            value = dict(results=[project], next=None)
        elif '/issues/abc/' in self.path:
            value = issue
        else:
            value = dict(results=[issue], next=None if 'cursor=' in self.path else base + '/api/canonical/0/issues/?project=1&cursor=next')
        if self.server.bad_next and 'results' in value:
            value['next'] = self.server.bad_next
        body = json.dumps(value).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.events.append((self.path, self.headers.get('X-Sentry-Auth'), self.headers.get('Authorization'), body))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'id': body['event_id']}).encode())


class Tests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.requests = []
        self.server.events = []
        self.server.redirect = False
        self.server.bad_dsn = False
        self.server.bad_next = None
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.env = {**os.environ, 'BUGSINK_TEST_URL': f'http://127.0.0.1:{self.server.server_port}', 'BUGSINK_TEST_TOKEN': TOKEN}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def run_cli(self, *args):
        return subprocess.run(['python3', str(HELPER), *args], env=self.env, text=True, capture_output=True, timeout=10)

    def test_projects_read_without_exposing_dsn(self):
        r = self.run_cli('projects')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Smoke project', r.stdout)
        self.assertNotIn(KEY, r.stdout + r.stderr)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_issues_follow_pages_and_scrub_embedded_credentials(self):
        r = self.run_cli('issues', '--project', '1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(r.stdout)), 2)
        for secret in (KEY, TOKEN, 'hidden', 'FAKE-PASSWORD', 'FAKE-KEY', 'RkFLRTpQQVNT'):
            self.assertNotIn(secret, r.stdout + r.stderr)

    def test_issue_details(self):
        r = self.run_cli('issue', 'abc')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['id'], 'abc')

    def test_smoke_fetches_dsn_and_submits_unique_event_without_api_token(self):
        for _ in range(2):
            r = self.run_cli('smoke', '--project', '1')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('submitted', r.stdout)
            self.assertNotIn(KEY, r.stdout + r.stderr)
            self.assertNotIn(TOKEN, r.stdout + r.stderr)
        first, second = self.server.events
        self.assertEqual(first[0], '/api/1/store/')
        self.assertIn('sentry_key=' + KEY, first[1])
        self.assertIsNone(first[2])
        self.assertNotEqual(first[3]['fingerprint'], second[3]['fingerprint'])
        self.assertEqual(first[3]['level'], 'error')

    def test_rejects_redirect(self):
        self.server.redirect = True
        r = self.run_cli('projects')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.server.requests), 1)
        self.assertNotIn('Traceback', r.stderr)

    def test_rejects_external_dsn(self):
        self.server.bad_dsn = True
        r = self.run_cli('smoke', '--project', '1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.server.events, [])
        self.assertNotIn('private-key', r.stderr)

    def test_rejects_pagination_escape_and_loop(self):
        for next_url in ('https://evil.invalid/', self.env['BUGSINK_TEST_URL'] + '/api/canonical/0/projects/'):
            self.server.bad_next = next_url
            r = self.run_cli('projects')
            self.assertNotEqual(r.returncode, 0)

    def test_test_override_cannot_use_remote_host_or_omit_fake_token(self):
        self.env['BUGSINK_TEST_URL'] = 'https://evil.invalid'
        self.assertNotEqual(self.run_cli('projects').returncode, 0)
        self.env['BUGSINK_TEST_URL'] = f'http://127.0.0.1:{self.server.server_port}'
        self.env.pop('BUGSINK_TEST_TOKEN')
        self.assertNotEqual(self.run_cli('projects').returncode, 0)
        self.assertEqual(self.server.requests, [])


if __name__ == '__main__':
    unittest.main()
