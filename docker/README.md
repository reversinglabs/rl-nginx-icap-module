# Docker stack

Docker Compose stack that runs nginx with the `ngx_http_detect_icap_module`
dynamic module loaded, fronting a small demo backend, plus an optional
observability stack (Prometheus, Loki, Promtail, Grafana) for metrics and
logs. See the [top-level README](../README.md) for what this project is
overall; this covers running it.

Commands below assume you're `cd`'d into this `docker/` directory.

## Layout

| Path                                | Description                                                        |
|--------------------------------------|--------------------------------------------------------------------|
| `docker-compose.yml`                 | nginx (ce + plus variants), backend, certificates (self-signed TLS) |
| `docker-compose-certgen.yml`         | self-signed cert generator (never combine with `docker-compose-certbot.yml`) |
| `docker-compose-tls.yml`             | adds the ICAP-over-TLS trusted CA cert mount — include only when `ICAP_SCHEME=https` |
| `docker-compose.observability.yml`   | nginx-exporter, promtail, loki, prometheus, grafana                 |
| `Dockerfile.nginx`                   | `nginx_ce`: Docker Hub nginx + pre-built module                     |
| `Dockerfile.nginx-plus`              | `nginx_plus`: NGINX Plus (external `.deb`) + pre-built module       |
| `Dockerfile.backend`                 | demo backend (records uploads, serves files)                       |
| `.env-default` / `.env-local` / `.env-rl-dev` / `.env-rl-dev-tls` | per-environment config; symlink whichever you want as `.env` |
| `observability/`                     | Loki / Prometheus / Promtail / Grafana config                      |

Also referenced from here, one level up at the repo root:

| Path                   | Description                                            |
|-------------------------|---------------------------------------------------------|
| `../nginx.docker.conf`  | nginx config template (envsubst'd at container start)   |
| `../module/`            | put the pre-built `.so` here (gitignored)               |
| `../backend/`           | demo backend source                                      |
| `../files/`             | sample files the backend serves back over GET            |

## Prerequisites

- Docker and Docker Compose v2 (`docker compose ...`).
- The module built from source (specific for NGINX_VERSION and UBUNTU_VERSION)
- Local ICAP server or one that is reachable (REQMOD/RESPMOD) to scan traffic through. Point `ICAP_HOSTNAME`/`ICAP_PORT` (below) at it.

## Setup

1. Copy the pre-built module into the repo's `module/` folder (one level up
   from here) and symlink it to the name the Dockerfiles expect `ngx_http_detect_icap_module.so`.

   ```bash
   # Copy pre-built module
   mkdir -p ../module
   cp /path/to/nginx-icap-module-*_amd64.so ../module/
   
   # Create symlink
   cd ../module
   ln -sf nginx-icap-module-*_amd64.so ngx_http_detect_icap_module.so
   ```

2. Create env. var file. Directory may contain multiple environment files
   (`.env-default`, `.env-local`, `.env-rl-dev`, `.env-rl-dev-tls`, or any
   others you add), each a pre-filled variant for a specific setup. However,
   Docker Compose only ever reads the file literally named `.env`; select
   which configuration is active by symlinking it accordingly:

   ```bash
   # Copy template
   cp .env-default .env-dev
   
   # Modify env file and make it current by creating symlink
   ln -sf .env-dev .env
   ```

   Edit whichever file you symlinked in .env:
   - `COMPOSE_PROFILES` — include
     - `ce` for the Docker-Hub-nginx variant
     - `plus` for NGINX Plus
     - `test` for the `tester` service
     - `local-icap` for a bundled dummy ICAP server (skip it if you're
       pointing at a real one via `ICAP_HOSTNAME` below)

   Common requirements:
   - `ICAP_HOSTNAME` / `ICAP_PORT` / `ICAP_SCHEME` / `ICAP_SERVICE` — your
     ICAP server. If it's on the Docker host rather than reachable by DNS,
     use `host.docker.internal` (Linux: add `extra_hosts:
     ["host.docker.internal:host-gateway"]` to the `nginx` service, or use
     the host's LAN IP).
   
   ICAP TLS requirements:
   - if ICAP server has self-signed certificate use following steps
     ```bash
     # fetch server certificate
     echo | openssl s_client -connect <icap-server>:<icap-server TLS port> -servername <server-name> 2>/dev/null | openssl x509 -outform PEM > icap-server-certificate.pem
     # display certificate in plain text format
     openssl x509 -in icap-server-certificate.pem -noout -text
     # extract CN from certificate
     openssl x509 -in icap-server-certificate.pem -noout -subject | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p'
     ```
     - ICAP_SSL_TRUSTED_CERT=icap-server-certificate.pem
     - ICAP_SSL_NAME=<extracted CN name>
   - The cert file above (`icap-server-certificate.pem`, next to whichever
     `.env` you symlinked, i.e. this `docker/` directory) only actually gets
     into the container if you also add `-f docker-compose-tls.yml` to every
     `docker compose` command below — it's a separate override, not part of
     the base `docker-compose.yml`, specifically so a non-TLS run (`ICAP_SCHEME=http`,
     `ICAP_SSL_TRUSTED_CERT` unset) never needs this bind mount at all. See
     [Running](#running) for exactly where it goes.

   Specific requirements:
   - CE
     - `NGINX_VERSION` **must** match the nginx core version the `.so` was
       built against — nginx refuses to load a dynamic module built against
       a different core version (`module ... is not binary compatible`).
   - Plus
     - `UBUNTU_VERSION` must match the Ubuntu release of your NGINX Plus
       `.deb`.
     - `NGINX_PLUS_SW_ROOT` is the directory holding your NGINX Plus install
       package(s) — doesn't need to live in this repo.
     - `NGINX_PLUS_DEB` is a filename (or relative path) resolved against
       `NGINX_PLUS_SW_ROOT`.
     - `NGINX_PLUS_LICENSE` is a plain path to your NGINX Plus license
       `.jwt` (not resolved against `NGINX_PLUS_SW_ROOT`).

## Running

Base stack (nginx using self-signed TLS + backend):

```bash
docker compose \
      -f docker-compose.yml \
      -f docker-compose-certgen.yml \
      up -d --build
```

With observability included:

```bash
docker compose \
      -f docker-compose.yml \
      -f docker-compose-certgen.yml \
      -f docker-compose.observability.yml \
      up -d --build
```

With ICAP over TLS (`ICAP_SCHEME=https` in your `.env` — see [ICAP TLS
requirements](#setup) in Setup) — add `-f docker-compose-tls.yml`, combine
with the others above as needed:

```bash
docker compose \
      -f docker-compose.yml \
      -f docker-compose-certgen.yml \
      -f docker-compose-tls.yml \
      -f docker-compose.observability.yml \
      up -d --build
```

Test environment:

```bash
docker compose exec tester sh
```

Bring it down (`-v` also drops the named volumes — certs, logs, dashboards
state):

```bash
docker compose -f docker-compose.yml \
               -f docker-compose-certgen.yml \
               -f docker-compose-tls.yml \
               -f docker-compose.observability.yml \
               down -v
```

## Endpoints

| Service      | URL                              | Notes                          |
|--------------|-----------------------------------|---------------------------------|
| nginx (HTTP) | http://localhost:${NGINX_PORT:-80} | proxies through ICAP to backend |
| nginx (HTTPS)| https://localhost:${NGINX_HTTPS_PORT:-443} | self-signed cert |
| Grafana      | http://localhost:3000             | anonymous admin access          |

## Verifying it's working

Execute following commands from host machine:

```bash
# nginx + module loaded, backend reachable (bypasses the ICAP path):
# Note: assumes SAMPLES_FOLDER is set to ../files/
curl -s http://localhost/clean.txt   # served from ../files/, proxied through nginx

# traffic through the ICAP path — requires a live ICAP server:
curl -s -X POST --data-binary "clean upload" http://localhost/up

# EICAR (../files/eicar, the standard AV test string — not real malware)
# should be REJECTED via REQMOD; expect 403, not 200:
curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST --data-binary @../files/eicar http://localhost/up
```

If Grafana/observability is up, the "ICAP Overview" dashboard
(`observability/grafana/dashboards/icap-overview.json`) shows request
throughput, REQMOD/RESPMOD outcomes (parsed from nginx's `icap.log` by
Promtail), and backend metrics.

## Limitations

### 1. Non-blocking upstream API

| Impact | Trigger | Status |
|--------|---------|--------|
| One slow or hung ICAP server stalls an entire worker — and every other connection it multiplexes — for up to `connect + send + read` timeout. The shipped config sets `detect_icap_read_timeout 3m`, so a handful of slow requests can wedge the gateway for minutes. Documented by the authors as a known limitation. | Any request to a scanned location while the ICAP server is slow, overloaded, or unreachable; also reachable by an attacker who can slow the ICAP path. | Will not be implemented for PoC. |

### 2. In-memory-only body buffering, fail-closed

The module never streams to ICAP — it buffers the whole request/response
body in memory first, and only scans what nginx itself already held in
memory. Once nginx spills a body to a temp file (past
`client_body_buffer_size` for requests, or `proxy_buffers` for responses),
the two directions diverge:

- REQMOD (`ngx_http_detect_icap_collect_body`) detects the file-backed
  buffer and fails **closed** — `500 Internal Server Error`, the request
  never reaches the backend.

## Troubleshooting

- **`nginx: [emerg] module ... is not binary compatible`** — `NGINX_VERSION`
  in `.env` doesn't match the core the `.so` was built against. Rebuild the
  module for this version, or change `NGINX_VERSION` to match.
- **`nginx`/`nginx_plus` container exits immediately, or a build error
  naming `module/ngx_http_detect_icap_module.so`** — either you skipped
  Setup step 1, or the file/symlink in `../module/` is missing/dangling or
  misnamed (it must be exactly `ngx_http_detect_icap_module.so`, not e.g.
  `nginx_http_detect_icap-module.so` — `ngx`/underscore throughout, not
  `nginx`/hyphen — and its symlink target, if it is one, must be a bare
  filename, not prefixed with `module/` again).
- **`nginx_plus` build fails with `failed to get build context
  nginx-plus-sw-root: ... no such file or directory`, or `NGINX_PLUS_DEB
  not set`** — `NGINX_PLUS_SW_ROOT`/`NGINX_PLUS_DEB` in your `.env` are
  either unset or point at a directory/filename that doesn't actually exist;
  double check both independently (`NGINX_PLUS_DEB` is resolved *inside*
  `NGINX_PLUS_SW_ROOT`, not this repo).
- **ICAP timeouts / 502s** — `ICAP_HOSTNAME`/`ICAP_PORT` isn't reachable
  from inside the `nginx` container; test with
  `docker compose exec nginx_ce sh -c 'curl -v telnet://$ICAP_HOSTNAME:$ICAP_PORT'`
  (substitute `nginx_plus` if that's the active profile).
- **`service "nginx" is not running`** — `nginx` is only a network *alias*
  (see `docker-compose.yml`'s `x-nginx_base`), not a real service name;
  `docker compose exec`/`logs` need the actual one, `nginx_ce` or
  `nginx_plus`, whichever profile is active.
- **`nginx: [emerg] ... failed to load detect_icap_ssl_trusted_certificate
  "/etc/nginx/icap-ca.crt"`** (`ICAP_SCHEME=https`) — you forgot `-f
  docker-compose-tls.yml` on this `up`/`build`, so the CA cert never got
  bind-mounted in. Add it (see [Running](#running)). If you *did* include it
  and just changed `nginx.docker.conf` or `docker-compose*.yml`, also make
  sure you rebuilt (`--build`) — `nginx.docker.conf` is baked into the image
  at build time, so editing it on disk alone has no effect on an
  already-built image.
