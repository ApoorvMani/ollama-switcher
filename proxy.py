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
TIMEOUT = 180  # 3 min — covers cold model load (11GB on Colab T4 takes ~60s)
DEFAULT_NUM_CTX = int(os.environ.get("OLLAMA_NUM_CTX", 32768))

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
    "content-length",       # let urllib set it from actual body bytes
    "transfer-encoding",    # must not forward - we reassemble the body fully
    "accept-encoding",      # prevent gzip response we can't transparently re-encode
})
_STRIP_RESPONSE_HEADERS = frozenset({
    "transfer-encoding", "connection", "keep-alive",
    "proxy-authenticate", "proxy-authorization", "te", "trailers", "upgrade",
})

INJECT_ENDPOINTS = {"/api/chat", "/api/generate"}
RESPONSE_MODIFY_ENDPOINTS = {"/api/tags", "/api/show", "/api/ps"}


def inject_options(body: bytes) -> bytes:
    """Inject performance options into request body for /api/chat and /api/generate."""
    if not body:
        return body
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return body

    opts = data.setdefault("options", {})
    opts.setdefault("num_ctx", DEFAULT_NUM_CTX)
    opts.setdefault("num_gpu", 99)       # offload all layers to GPU
    opts.setdefault("num_batch", 512)    # larger batch = faster prompt ingestion
    opts.setdefault("flash_attn", True)  # flash attention for speed + lower VRAM

    # Keep model loaded 10 min between requests (default is 5 min)
    data.setdefault("keep_alive", "10m")

    return json.dumps(data).encode()


def modify_response(body: bytes, endpoint: str) -> bytes:
    """Modify response to show num_ctx in model info."""
    if not body:
        return body
    
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return body
    
    original = json.dumps(data)
    
    if endpoint == "/api/tags":
        if "models" in data:
            for model in data["models"]:
                if "model" in model:
                    model["size"] = 10737418240
    elif endpoint == "/api/ps":
        if "models" in data:
            for model in data["models"]:
                log.info(f"Before modify: context_length = {model.get('context_length')}")
                model["context_length"] = DEFAULT_NUM_CTX
                log.info(f"After modify: context_length = {model.get('context_length')}")
    
    modified = json.dumps(data)
    if original != modified:
        log.info(f"Modified response for {endpoint}")
    
    return modified.encode()


class ProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
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

        # Inject performance options for chat/generate endpoints
        if self.path in INJECT_ENDPOINTS and body:
            body = inject_options(body)
            content_length = len(body)

        req = urllib.request.Request(url=target, data=body, method=self.command)

        for key, val in self.headers.items():
            if key.lower() not in _STRIP_REQUEST_HEADERS:
                req.add_header(key, val)
        
        # urllib sets Content-Length from data automatically; only force it if
        # we modified the body (inject_options changes the byte count)
        if body is not None:
            req.add_header("Content-Length", str(len(body)))

        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                log.info(f"{self.command} {self.path} → {resp.status}")
                self.send_response(resp.status)
                for key, val in resp.headers.items():
                    k = key.lower()
                    if k not in _STRIP_RESPONSE_HEADERS and k != "content-length":
                        self.send_header(key, val)
                # NOTE: end_headers() called once, inside each branch below

                if self.path in RESPONSE_MODIFY_ENDPOINTS:
                    full_body = resp.read()
                    modified_body = modify_response(full_body, self.path)
                    self.send_header("Content-Length", str(len(modified_body)))
                    self.end_headers()
                    self.wfile.write(modified_body)
                    self.wfile.flush()
                else:
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
                    k = key.lower()
                    if k not in _STRIP_RESPONSE_HEADERS and k != "content-length":
                        self.send_header(key, val)
                exc_body = exc.read()
                if self.path in RESPONSE_MODIFY_ENDPOINTS:
                    modified = modify_response(exc_body, self.path)
                    self.send_header("Content-Length", str(len(modified)))
                    self.end_headers()
                    self.wfile.write(modified)
                else:
                    self.send_header("Content-Length", str(len(exc_body)))
                    self.end_headers()
                    self.wfile.write(exc_body)
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
    log.info(f"Using num_ctx: {DEFAULT_NUM_CTX}")

    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    log.info("Proxy ready.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Proxy stopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
