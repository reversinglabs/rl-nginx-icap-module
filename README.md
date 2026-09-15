# Nginx ICAP dynamic module - DEMO

Docker Compose stack that runs nginx with the `ngx_http_detect_icap_module`
dynamic module loaded, fronting a small demo backend, plus an observability
stack (Prometheus, Loki, Promtail, Grafana) for metrics and logs.

This project does **not** build the module — it only runs a pre-built
`.so`. Build it in the sibling [`nginx-icap-module-src`](../nginx-icap-module-src)
repo first.

## Layout

```
docker/                           compose files, Dockerfiles, env files — cd here to run anything below
  docker-compose.yml               nginx (ce + plus variants), backend, certificates (self-signed TLS)
  docker-compose-certgen.yml       self-signed cert generator (never combine with docker-compose-certbot.yml)
  docker-compose.observability.yml nginx-exporter, promtail, loki, prometheus, grafana
  Dockerfile.nginx                 nginx_ce: Docker Hub nginx + pre-built module
  Dockerfile.nginx-plus            nginx_plus: NGINX Plus (external .deb) + pre-built module
  Dockerfile.backend               demo backend (records uploads, serves files)
  .env-default / .env-local / .env-rl-dev / .env-rl-dev-tls
                                    per-environment config; symlink whichever you want as .env
  observability/                   Loki / Prometheus / Promtail / Grafana config
nginx.docker.conf                nginx config template (envsubst'd at container start)
module/                          put the pre-built .so here (gitignored)
backend/                         demo backend source
files/                           sample files the backend serves back over GET
```

## Prerequisites

- Docker and Docker Compose v2 (`docker compose ...`).
- The module built from source

  This produces
  `build/nginx-icap-module-<nginx version>-<git ref>-<ubuntu codename>_amd64.so`.

- A reachable ICAP server (REQMOD/RESPMOD) to scan traffic through. This
  stack does not run one — it's assumed to be an external appliance/service
  you already have. Point `ICAP_HOSTNAME`/`ICAP_PORT` (below) at it.

## Setup

1. Copy the pre-built module into this project's folder 'module'. Create symbolic link pointing to dynamic module.
   Link name should be `ngx_http_detect_icap_module.so`):

   ```bash
   mkdir -p module
   ln -sf module/nginx-icap-module-*_amd64.so module/ngx_http_detect_icap_module.so
   ```

2. Pick an env file — `docker/.env-default` is the generic starting point;
   `.env-local`/`.env-rl-dev`/`.env-rl-dev-tls` are pre-filled variants for
   specific setups — and symlink it as `docker/.env` (compose auto-loads
   whatever `.env` in its own directory resolves to):

   ```bash
   cd docker
   cp .env-default .env-dev
   ln -sf .env-dev .env
   ```

Edit whichever file you symlinked:
   - `COMPOSE_PROFILES` — include 
     - `ce` for the Docker-Hub-nginx variant.
     - `plus` for NGINX Plus
     - `test` for the `tester` service
     - `local-icap` for a bundled dummy ICAP server (skip it if you're pointing at a real
       one via `ICAP_HOSTNAME` below).

Common requirements:
  - `ICAP_HOSTNAME` / `ICAP_PORT` / `ICAP_SCHEME` / `ICAP_SERVICE` — your
     ICAP server. If it's on the Docker host rather than reachable by DNS,
     use `host.docker.internal` (Linux: add `extra_hosts:
     ["host.docker.internal:host-gateway"]` to the `nginx` service, or use
     the host's LAN IP).

Specific requirements:
  - CE
    - `NGINX_VERSION` **must** match the nginx core version the `.so` was built against — nginx refuses to load a dynamic module built against a 
       different core version (`module ... is not binary compatible`).
  - Plus
    - `UBUNTU_VERSION` must match the Ubuntu release of your NGINX
    - `NGINX_PLUS_SW_ROOT` is the directory holding your NGINX Plus install package(s) — doesn't need to live in this repo;
    - `NGINX_PLUS_DEB` is a filename (or relative path) resolved against NGINX_PLUS_SW_ROOT.
    - `NGINX_PLUS_LICENSE` is a plain path to your NGINX Plus license `.jwt` (not resolved against `NGINX_PLUS_SW_ROOT`).

## Running

All commands below run from `docker/` (where the compose files actually
live).
```bash
cd docker
```

Base stack (nginx + backend + self-signed TLS):

```bash
docker compose \
      -f docker-compose.yml \
      -f docker-compose-certgen.yml \
      up -d
```

With observability included:

```bash
docker compose \
      -f docker-compose.yml \
      -f docker-compose-certgen.yml \
      -f docker-compose.observability.yml \
      up -d
```

Test environment
```bash
docker compose exec tester sh
```

Bring it down (`-v` also drops the named volumes — certs, logs, dashboards state):

```bash
docker compose -f docker-compose.yml \
               -f docker-compose-certgen.yml \
               -f docker-compose.observability.yml down -v
```

## Endpoints

| Service      | URL                              | Notes                          |
|--------------|-----------------------------------|---------------------------------|
| nginx (HTTP) | http://localhost:${NGINX_PORT:-80} | proxies through ICAP to backend |
| nginx (HTTPS)| https://localhost:${NGINX_HTTPS_PORT:-443} | self-signed cert |
| Grafana      | http://localhost:3000             | anonymous admin access          |

## Verifying it's working

```bash
# nginx + module loaded, backend reachable (bypasses the ICAP path):
curl -s http://localhost:80/clean.txt   # served from files/, proxied through nginx

# stub_status (only reachable inside the docker network, e.g. from nginx-exporter):
docker compose exec nginx curl -s http://localhost:8081/stub_status

# module actually loaded (check nginx's error log for the module version line):
docker compose logs nginx | grep -i module

# traffic through the ICAP path — requires a live ICAP server:
curl -s -X POST --data-binary "clean upload" http://localhost:80/anything
```

If Grafana/observability is up, the "ICAP Overview" dashboard (`observability/grafana/dashboards/icap-overview.json`) shows request
throughput, REQMOD/RESPMOD outcomes (parsed from nginx's `icap.log` by Promtail), and backend metrics.

## Troubleshooting

- **`nginx: [emerg] module ... is not binary compatible`** — `NGINX_VERSION`
  in `.env` doesn't match the core the `.so` was built against. Rebuild the
  module for this version, or change `NGINX_VERSION` to match.
- **`nginx`/`nginx_plus` container exits immediately, or a build error
  naming `module/ngx_http_detect_icap_module.so`** — either you skipped
  Setup step 1, or the file/symlink in `module/` is misnamed (it must be
  exactly `ngx_http_detect_icap_module.so`, not e.g.
  `nginx_http_detect_icap-module.so` — `ngx`/underscore throughout, not
  `nginx`/hyphen).
- **`nginx_plus` build fails with `failed to get build context
  nginx-plus-sw-root: ... no such file or directory`, or `NGINX_PLUS_DEB
  not set`** — `NGINX_PLUS_SW_ROOT`/`NGINX_PLUS_DEB` in your `.env` are
  either unset or point at a directory/filename that doesn't actually exist;
  double check both independently (`NGINX_PLUS_DEB` is resolved *inside*
  `NGINX_PLUS_SW_ROOT`, not this repo).
- **ICAP timeouts / 502s** — `ICAP_HOSTNAME`/`ICAP_PORT` isn't reachable
  from inside the `nginx` container; test with
  `docker compose exec nginx sh -c 'curl -v telnet://$ICAP_HOSTNAME:$ICAP_PORT'`.
