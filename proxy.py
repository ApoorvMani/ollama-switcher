#!/usr/bin/env python3
"""
proxy.py - Ollama reverse proxy
Listens on 0.0.0.0:11434 and forwards all requests to COLAB_URL from .env.
Returns 503 on connection failure so callers get a clean error.
Streams NDJSON responses chunk-by-chunk - never buffers full response body.
"""

import http.server
import socketserver
import urllib.request
import urllib.error
import json
import os
import sys
import logging

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 11434
CHUNK_SIZE = 4096
TIMEOUT = 30

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(SCRIPT_DIR, ".env")
LOG_FILE = os.path.join(SCRIPT_DIR, "proxy.log")

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger(__name__)


def load_colab_url():
    """Read COLAB_URL from .env in same directory as this script."""
    if not os.path.exists(ENV_FILE):
        raise FileNotFoundError(f".env not found: {ENV_FILE}")
    with open(ENV_FILE, encoding="utf-8-sig") as f:  # utf-8-sig strips BOM if present
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                if key.strip() == "COLAB_URL":
                    return val.strip()
    raise ValueError("COLAB_URL not found in .env")


# Headers that must not be forwarded verbatim (connection-specific or handled by urllib)
_STRIP_REQUEST_HEADERS = frozenset({
    "host", "connection", "proxy-connection", "keep-alive",
    "te", "trailers", "upgrade",
})
_STRIP_RESPONSE_HEADERS = frozenset({
    "transfer-encoding", "connection", "keep-alive",
    "proxy-authenticate", "proxy-authorization", "te", "trailers", "upgrade",
})


class ProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Suppress default stderr logging - we use our own
        pass

    def _send_503(self, reason: str):
        body = json.dumps({"error": reason}).encode()
        try:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            pass  # client may have disconnected

    def _proxy(self):
        # Re-read .env on every request so URL updates are picked up without restart
        try:
            colab_url = load_colab_url()
        except Exception as exc:
            log.error(f"Config error: {exc}")
            self._send_503(f"Proxy config error: {exc}")
            return

        target = colab_url.rstrip("/") + self.path

        # Read request body (present on POST/PUT/PATCH)
        content_length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(content_length) if content_length > 0 else None

        req = urllib.request.Request(url=target, data=body, method=self.command)

        for key, val in self.headers.items():
            if key.lower() not in _STRIP_REQUEST_HEADERS:
                req.add_header(key, val)

        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                log.info(f"{self.command} {self.path} → {resp.status}")
                self.send_response(resp.status)
                for key, val in resp.headers.items():
                    if key.lower() not in _STRIP_RESPONSE_HEADERS:
                        self.send_header(key, val)
                self.end_headers()

                # Stream in chunks - critical for NDJSON / Ollama streaming
                while True:
                    chunk = resp.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()

        except urllib.error.HTTPError as exc:
            # Forward actual HTTP errors from Colab (4xx, 5xx) as-is
            log.error(f"{self.command} {self.path} → HTTP {exc.code}: {exc.reason}")
            try:
                self.send_response(exc.code)
                for key, val in exc.headers.items():
                    if key.lower() not in _STRIP_RESPONSE_HEADERS:
                        self.send_header(key, val)
                self.end_headers()
                self.wfile.write(exc.read())
            except Exception:
                pass

        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as exc:
            reason = str(exc)
            log.error(f"{self.command} {self.path} → 503: {reason}")
            self._send_503(reason)

    # Wire every HTTP method to the same proxy handler
    do_GET = _proxy
    do_POST = _proxy
    do_PUT = _proxy
    do_DELETE = _proxy
    do_HEAD = _proxy
    do_PATCH = _proxy
    do_OPTIONS = _proxy


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Handle each request in its own thread (needed for concurrent streaming)."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    try:
        colab_url = load_colab_url()
    except Exception as exc:
        log.error(f"Startup failed: {exc}")
        sys.exit(1)

    log.info(f"Ollama proxy starting on {LISTEN_HOST}:{LISTEN_PORT}")
    log.info(f"Forwarding to: {colab_url}")

    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    log.info("Proxy ready.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Proxy stopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
