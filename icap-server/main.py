#!/usr/bin/env python3
"""Reference ICAP (RFC 3507) server for ngx_http_detect_icap_module — see
docs/MODULE.md (wire protocol) and docs/ARCHITECTURE.md (swapping in a real
scan engine)."""

import os
import socket
import socketserver
import ssl
import threading
import logging
import re

LOG = logging.getLogger("detect-icap")

ICAP_PORT = 1344
SERVICE_PATH = "/detect"

ICAPS_PORT = int(os.environ.get("ICAPS_PORT", "11344"))
ICAPS_CERTFILE = os.environ.get("ICAPS_CERTFILE")
ICAPS_KEYFILE = os.environ.get("ICAPS_KEYFILE")

# The EICAR standard anti-malware test string (safe; not real malware).
# Assembled at runtime so this source file itself never contains the full
# trigger string contiguously.
EICAR = (
    "X5O!P%@AP[4\\PZX54(P^)7CC)7}"
    + "$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
).encode()

SIGNATURES = [
    EICAR,
    b"malware-demo-signature",
]


def scan_payload(http_body: bytes) -> tuple[bool, str]:
    """Return (is_malicious, reason). Swap this for the real Detect engine."""
    for sig in SIGNATURES:
        if sig and sig in http_body:
            return True, "signature match"
    return False, "clean"


class ICAPError(Exception):
    pass


class Handler(socketserver.StreamRequestHandler):

    timeout = 120

    def handle(self):
        try:
            while True:
                if not self._handle_one():
                    break
        except (ICAPError, ConnectionError, socket.timeout) as e:
            LOG.warning("connection ended: %s", e)

    # ---- low level helpers ----
    def _read_line(self) -> bytes:
        line = self.rfile.readline()
        if not line:
            raise ICAPError("client closed")
        return line.rstrip(b"\r\n")

    def _read_headers(self) -> list[bytes]:
        headers = []
        while True:
            line = self.rfile.readline()
            if line in (b"\r\n", b"\n", b""):
                break
            headers.append(line.rstrip(b"\r\n"))
        return headers

    def _parse_encapsulated(self, headers: list[bytes]) -> dict:
        for h in headers:
            if h.lower().startswith(b"encapsulated:"):
                spec = h.split(b":", 1)[1].decode().strip()
                out = {}
                for part in spec.split(","):
                    k, _, v = part.strip().partition("=")
                    out[k.strip()] = int(v)
                return out
        return {}

    def _read_chunked_body(self) -> bytes:
        """Read an ICAP/HTTP chunked body terminated by a 0-length chunk."""
        body = bytearray()
        while True:
            size_line = self.rfile.readline()
            if not size_line:
                break
            size_line = size_line.strip()
            if size_line == b"":
                continue
            # chunk-size may carry extensions after ';'
            try:
                size = int(size_line.split(b";")[0], 16)
            except ValueError:
                break
            if size == 0:
                # consume trailing CRLF
                self.rfile.readline()
                break
            chunk = self.rfile.read(size)
            body.extend(chunk)
            self.rfile.read(2)  # trailing CRLF
        return bytes(body)

    # ---- request dispatch ----
    def _handle_one(self) -> bool:
        request_line = self._read_line()
        parts = request_line.split(b" ")
        if len(parts) < 3:
            raise ICAPError(f"bad ICAP request line: {request_line!r}")
        method = parts[0].upper()
        LOG.info("ICAP %s", request_line.decode(errors="replace"))

        headers = self._read_headers()

        if method == b"OPTIONS":
            return self._do_options()
        elif method == b"REQMOD":
            return self._do_reqmod(headers)
        elif method == b"RESPMOD":
            return self._do_reqmod(headers)  # same scan logic, response side
        else:
            self._send_status(405, "Method Not Allowed")
            return True

    def _do_options(self) -> bool:
        body = (
            b"ICAP/1.0 200 OK\r\n"
            b"Methods: REQMOD RESPMOD\r\n"
            b"Service: Detect ICAP Server 1.0\r\n"
            b"ISTag: \"detect-0001\"\r\n"
            b"Allow: 204\r\n"
            b"Preview: 0\r\n"
            b"Encapsulated: null-body=0\r\n"
            b"\r\n"
        )
        self.wfile.write(body)
        self.wfile.flush()
        return True

    def _do_reqmod(self, headers: list[bytes]) -> bool:
        enc = self._parse_encapsulated(headers)

        # Skip encapsulated HTTP headers so the stream is positioned at the body.
        if "req-hdr" in enc and ("req-body" in enc or "null-body" in enc):
            end = enc.get("req-body", enc.get("null-body"))
            self.rfile.read(end - enc["req-hdr"])
        elif "res-hdr" in enc and ("res-body" in enc or "null-body" in enc):
            end = enc.get("res-body", enc.get("null-body"))
            self.rfile.read(end - enc["res-hdr"])

        body = b""
        if "req-body" in enc or "res-body" in enc:
            body = self._read_chunked_body()

        malicious, reason = scan_payload(body)
        LOG.info("scan verdict: malicious=%s reason=%s (%d body bytes)",
                 malicious, reason, len(body))

        if malicious:
            return self._send_block_page(reason)
        else:
            return self._send_204()

    def _send_204(self) -> bool:
        self.wfile.write(
            b"ICAP/1.0 204 No Modifications\r\n"
            b"ISTag: \"detect-0001\"\r\n"
            b"Encapsulated: null-body=0\r\n"
            b"\r\n"
        )
        self.wfile.flush()
        return True

    def _send_block_page(self, reason: str) -> bool:
        block_html = (
            b"<html><body><h1>403 Blocked</h1>"
            b"<p>Detect ICAP Server blocked this upload: "
            + reason.encode() +
            b"</p></body></html>"
        )
        http_resp_headers = (
            b"HTTP/1.1 403 Forbidden\r\n"
            b"Content-Type: text/html\r\n"
            b"Content-Length: " + str(len(block_html)).encode() + b"\r\n"
            b"\r\n"
        )
        # ICAP 200 OK carrying a modified (blocking) HTTP response.
        chunk = b"%x\r\n%s\r\n0\r\n\r\n" % (len(block_html), block_html)
        res_body_off = len(http_resp_headers)
        icap = (
            b"ICAP/1.0 200 OK\r\n"
            b"ISTag: \"detect-0001\"\r\n"
            b"Encapsulated: res-hdr=0, res-body=" + str(res_body_off).encode() + b"\r\n"
            b"\r\n"
            + http_resp_headers
            + chunk
        )
        self.wfile.write(icap)
        self.wfile.flush()
        return True


class ThreadedICAPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ThreadedICAPSServer(ThreadedICAPServer):
    """TLS-wrapped variant of ThreadedICAPServer — the ICAPS listener.

    Wraps each accepted socket in get_request(), the standard socketserver
    idiom for adding TLS: SSLError (a subclass of OSError) from a failed
    handshake is swallowed by BaseServer._handle_request_noblock's existing
    `except OSError` around get_request(), so one bad/non-TLS connection
    doesn't take the accept loop down.
    """

    def __init__(self, server_address, handler_cls, certfile, keyfile):
        super().__init__(server_address, handler_cls)
        self.ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ssl_context.load_cert_chain(certfile, keyfile)

    def get_request(self):
        sock, addr = super().get_request()
        return self.ssl_context.wrap_socket(sock, server_side=True), addr


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    servers = [ThreadedICAPServer(("0.0.0.0", ICAP_PORT), Handler)]
    LOG.info("Detect ICAP server listening on 0.0.0.0:%d (plaintext) service=%s",
             ICAP_PORT, SERVICE_PATH)

    if ICAPS_CERTFILE and ICAPS_KEYFILE:
        servers.append(ThreadedICAPSServer(
            ("0.0.0.0", ICAPS_PORT), Handler, ICAPS_CERTFILE, ICAPS_KEYFILE))
        LOG.info("Detect ICAP server listening on 0.0.0.0:%d (TLS) service=%s",
                 ICAPS_PORT, SERVICE_PATH)
    else:
        LOG.info("ICAPS_CERTFILE/ICAPS_KEYFILE not set — TLS (ICAPS) listener disabled")

    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        for s in servers:
            s.shutdown()


if __name__ == "__main__":
    main()
