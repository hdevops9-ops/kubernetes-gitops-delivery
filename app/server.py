"""Small stateless platform API; no third-party runtime dependencies."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

class Handler(BaseHTTPRequestHandler):
    server_version = "PlatformAPI"
    sys_version = ""
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz": status, data = 200, {"status":"ok"}
        elif path == "/readyz": status, data = 200, {"ready":True}
        elif path == "/": status, data = 200, {"service":"platform-api","version":os.getenv("RELEASE_VERSION","development")}
        else: status, data = 404, {"error":"not found"}
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body)))
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("X-Frame-Options","DENY")
        self.send_header("Content-Security-Policy","default-src 'none'; frame-ancestors 'none'")
        self.send_header("Cache-Control","no-store")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        print(json.dumps({"request":fmt % args}),flush=True)

def make_server(address=("0.0.0.0",8080)):  # nosec B104 - container service listens on its pod interface
    return ThreadingHTTPServer(address,Handler)

if __name__ == "__main__": make_server().serve_forever()
