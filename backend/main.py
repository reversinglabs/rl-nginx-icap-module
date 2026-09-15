#!/usr/bin/env python3
"""Trivial backend: records and acknowledges any upload that reaches it.
If a blocked request ever reaches here, the test FAILS.

GET /<filename>  — serve a file from FILES_DIR (default /files).
"""
import http.server
import logging
import mimetypes
import os
import shutil
import socket
import sys
import threading
import time
from urllib.parse import urlparse

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, REGISTRY, generate_latest
from prometheus_client.core import GaugeMetricFamily

# Container hostname (defaults to the container ID under Docker) — stamped on
# every response so you can confirm nginx is actually round-robining requests
# across multiple BACKEND_REPLICAS instances instead of pinning to one.
INSTANCE_ID = socket.gethostname()

# "endpoint" is a fixed logical name (upload/serve), not the raw request path —
# the path is an arbitrary uploaded/served filename and would blow up label
# cardinality if used directly.
REQUESTS_TOTAL = Counter(
    "backend_requests_total", "Total requests handled", ["method", "endpoint"]
)
# Counter, not a gauge: bytes/sec throughput is derived with rate() at query
# time (same approach as backend_requests_total), so a single running total
# survives scrape gaps instead of needing per-scrape bookkeeping.
BYTES_RECEIVED_TOTAL = Counter(
    "backend_bytes_received_total", "Total bytes received in request bodies", ["method", "endpoint"]
)
# Default buckets top out at 10s; uploads/downloads of large samples can run
# longer than that, so extend the ladder rather than losing them all into +Inf.
REQUEST_DURATION = Histogram(
    "backend_request_duration_seconds", "Request duration in seconds", ["method", "endpoint"],
    buckets=(.005, .01, .025, .05, .075, .1, .25, .5, .75, 1.0, 2.5, 5.0, 7.5, 10.0, 30.0, 60.0),
)
# Prometheus's "instance" scrape-target label already distinguishes replicas,
# so this doesn't need an INSTANCE_ID label of its own.
#
# A plain Gauge only reflects concurrency at the instant of a scrape, so a
# spike that starts and ends between two scrapes never shows up. This
# collector instead tracks the high-water mark since the last scrape and
# resets it on collect(), so a 5ms spike to 80 is still captured even if the
# scrape lands well after it's over. The start/end debug log line is kept
# alongside it for per-request tracing in Loki.
class ConcurrencyTracker:
    def __init__(self):
        self._lock = threading.Lock()
        self._current = 0
        self._peak = 0  # peak since last scrape

    def inc(self):
        with self._lock:
            self._current += 1
            if self._current > self._peak:
                self._peak = self._current
            return self._current

    def dec(self):
        with self._lock:
            self._current -= 1
            return self._current

    def collect(self):
        with self._lock:
            peak, self._peak = self._peak, self._current
            current = self._current
        g = GaugeMetricFamily(
            "backend_requests_in_progress", "Requests this backend instance is currently handling"
        )
        g.add_metric([], current)
        p = GaugeMetricFamily(
            "backend_requests_in_progress_peak",
            "Peak concurrent requests since last scrape",
        )
        p.add_metric([], peak)
        yield g
        yield p


CONCURRENCY = ConcurrencyTracker()
REGISTRY.register(CONCURRENCY)

LOG_FORMAT = f"%(asctime)s %(levelname)s [{INSTANCE_ID}] %(message)s"

logging.basicConfig(
    level=logging.DEBUG,
    format=LOG_FORMAT,
    stream=sys.stdout,
)
log = logging.getLogger("backend")

# Also mirror logs to a file so Promtail can tail them from a shared volume,
# same pattern as the nginx icap.log.
LOG_DIR = "/var/log/backend"
if os.path.isdir(LOG_DIR):
    file_handler = logging.FileHandler(os.path.join(LOG_DIR, "backend.log"))
    file_handler.setFormatter(logging.Formatter(LOG_FORMAT))
    log.addHandler(file_handler)

RECEIVED = []
FILES_DIR = "/files"


class H(http.server.BaseHTTPRequestHandler):

    def _handle_upload(self):
        method = self.command
        log.debug("event=request_start concurrency=%d method=%s endpoint=upload",
                  CONCURRENCY.inc(), method)
        t0 = time.monotonic()
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(length) if length else b""
            RECEIVED.append(data)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Backend-Instance", INSTANCE_ID)
            body = b"backend-ok: stored %d bytes\n" % len(data)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            REQUEST_DURATION.labels(method=method, endpoint="upload").observe(time.monotonic() - t0)
            REQUESTS_TOTAL.labels(method=method, endpoint="upload").inc()
            BYTES_RECEIVED_TOTAL.labels(method=method, endpoint="upload").inc(len(data))
        finally:
            log.debug("event=request_end concurrency=%d method=%s endpoint=upload",
                      CONCURRENCY.dec(), method)

    do_POST = _handle_upload
    do_PUT = _handle_upload

    def do_GET(self):
        url_path = urlparse(self.path).path.lstrip("/")
        if url_path == "metrics":
            self._handle_metrics()
            return

        log.debug("event=request_start concurrency=%d method=GET endpoint=serve",
                  CONCURRENCY.inc())
        t0 = time.monotonic()
        try:
            if not url_path:
                self._reply(400, b"missing path\n")
                return

            # Resolve to an absolute path and confirm it stays inside FILES_DIR.
            root     = os.path.realpath(FILES_DIR)
            filepath = os.path.realpath(os.path.join(root, url_path))
            if not filepath.startswith(root + os.sep) and filepath != root:
                self._reply(400, b"invalid path\n")
                return

            try:
                file_size = os.path.getsize(filepath)
                f = open(filepath, "rb")
            except FileNotFoundError:
                self._reply(404, b"not found\n")
                return
            except IsADirectoryError:
                self._reply(400, b"path is a directory\n")
                return

            mime = mimetypes.guess_type(filepath)[0] or "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(file_size))
            self.send_header("X-Backend-Instance", INSTANCE_ID)
            self.end_headers()
            try:
                shutil.copyfileobj(f, self.wfile, 65536)
            finally:
                f.close()
            REQUEST_DURATION.labels(method="GET", endpoint="serve").observe(time.monotonic() - t0)
            REQUESTS_TOTAL.labels(method="GET", endpoint="serve").inc()
        finally:
            log.debug("event=request_end concurrency=%d method=GET endpoint=serve",
                      CONCURRENCY.dec())

    def _handle_metrics(self):
        payload = generate_latest()
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE_LATEST)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info(fmt, *args)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    if len(sys.argv) > 2:
        FILES_DIR = sys.argv[2]
    log.info("serving files from %s on port %d", FILES_DIR, port)
    http.server.ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
