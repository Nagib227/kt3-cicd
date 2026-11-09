import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def version():
    return os.environ.get("APP_VERSION", "0.0.0")


def ready():
    return os.environ.get("READY", "true").lower() == "true"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/live"):
            self._send(200, {"status": "live", "version": version()})
        elif self.path.startswith("/ready"):
            code = 200 if ready() else 503
            self._send(code, {"status": "ready" if ready() else "not-ready", "version": version()})
        elif self.path.startswith("/api/announcements"):
            self._send(200, {"version": version(), "items": ["CampusBoard delivery"]})
        else:
            self._send(200, {"service": "campusboard", "version": version()})

    def _send(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
