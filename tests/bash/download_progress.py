#!/usr/bin/env python3
"""Exercise real curl through Loadout's newline-delimited pipe contract."""
import http.server
import os
import pathlib
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/error':
            self.send_error(503)
            return
        self.send_response(200)
        if self.path != '/unknown':
            self.send_header('Content-Length', str(1024 * 1024))
        self.end_headers()
        try:
            for chunk in range(256):
                self.wfile.write(b'x' * 4096)
                self.wfile.flush()
                time.sleep(.15 if chunk < 16 else .015)
        except (BrokenPipeError, ConnectionResetError):
            pass


class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def download(self, route):
        with tempfile.TemporaryDirectory(prefix='download test ') as tmp:
            process = subprocess.Popen(
                ['/bin/bash', '-c', 'source "$1"; dl "$2" "$3"', 'test',
                 os.environ.get('INSTALLER_LIB', str(ROOT / 'platforms/macos/installers/_lib.sh')),
                 f'http://127.0.0.1:{self.server.server_port}{route}',
                 str(pathlib.Path(tmp) / 'test.dmg')],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            lines = []
            for line in process.stdout:
                lines.append((line.strip(), process.poll() is None))
            process.stdout.close()
            return process.wait(timeout=10), lines

    def test_progress_arrives_before_download_finishes(self):
        code, lines = self.download('/known')
        self.assertEqual(code, 0, lines)
        progress = [(float(s[:-1]), live) for s, live in lines if s.endswith('%')]
        values = [p for p, _ in progress]
        self.assertTrue(all(p % 10 == 0 for p in values), lines)
        self.assertEqual(values, sorted(set(values)), lines)
        self.assertLessEqual(len(values), 11, lines)
        self.assertTrue(any(10 < p < 100 and live for p, live in progress), lines)
        self.assertEqual(progress[-1][0], 100, lines)

    def test_unknown_total_reports_bytes_while_running(self):
        code, lines = self.download('/unknown')
        self.assertEqual(code, 0, lines)
        self.assertTrue(any('bytes downloaded' in s and live for s, live in lines), lines)
        self.assertEqual(sum('bytes downloaded' in s for s, _ in lines), 1, lines)

    def test_http_failure_is_not_reported_as_success(self):
        code, lines = self.download('/error')
        self.assertNotEqual(code, 0)
        self.assertTrue(any('curl:' in s for s, _ in lines), lines)
        self.assertFalse(any(s == '100%' for s, _ in lines), lines)


if __name__ == '__main__':
    unittest.main()
