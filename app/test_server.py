import json
import os
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen
from server import make_server

class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=make_server(("127.0.0.1",0))
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.url=f"http://127.0.0.1:{cls.server.server_port}"
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def test_health_and_readiness(self):
        for path in ("/healthz","/readyz"):
            with urlopen(self.url+path,timeout=2) as r:self.assertEqual(r.status,200)
    def test_version_and_security_headers(self):
        with patch.dict(os.environ,{"RELEASE_VERSION":"test-release"}):
            with urlopen(self.url+"/",timeout=2) as r:
                self.assertEqual(json.load(r)["version"],"test-release")
                self.assertEqual(r.headers["X-Content-Type-Options"],"nosniff")
                self.assertEqual(r.headers["X-Frame-Options"],"DENY")
                self.assertIn("default-src 'none'",r.headers["Content-Security-Policy"])
    def test_unknown_route(self):
        with self.assertRaises(HTTPError) as e:urlopen(self.url+"/missing",timeout=2)
        self.assertEqual(e.exception.code,404);e.exception.close()
if __name__ == "__main__": unittest.main()
