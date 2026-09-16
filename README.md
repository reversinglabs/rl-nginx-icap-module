# Nginx ICAP dynamic module - DEMO

A working demo of `ngx_http_detect_icap_module`, the nginx dynamic module
that scans requests/responses via ICAP (REQMOD/RESPMOD) before they reach
the backend.

This project does **not** build the module — it only runs a pre-built
`.so`.

## Layout

| Path                 | Description                                                          |
|----------------------|-----------------------------------------------------------------------|
| `docker/`            | Docker Compose stack (nginx + backend + observability) — see `docker/README.md` |
| `terraform/`         | AWS deployment (Terraform) — see `terraform/ec2-nginx/README.md`      |
| `nginx.docker.conf`  | nginx config template (envsubst'd at container start)                 |
| `module/`            | put the pre-built `.so` here (gitignored)                             |
| `backend/`           | demo backend source                                                    |
| `files/`             | sample files the backend serves back over GET                          |

## Running it locally in docker stack

See [`docker/README.md`](docker/README.md) — setup, running with/without
observability, endpoints, verifying it's working, and troubleshooting.

## Deploying to AWS

See [`terraform/ec2-nginx/README.md`](terraform/ec2-nginx/README.md) —
stands up a self-contained EC2 instance running this same Docker stack.
