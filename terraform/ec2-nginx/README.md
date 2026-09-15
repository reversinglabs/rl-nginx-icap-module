# EC2 + Nginx (Terraform)

Stands up a self-contained EC2 instance running nginx, in its own VPC —
no dependency on default VPC/subnets in the target AWS account.

## What it creates

- VPC (`10.20.0.0/16` by default) with DNS support/hostnames enabled
- Internet Gateway + public route table (`0.0.0.0/0` → IGW)
- One public subnet (auto-assigns public IPs)
- Security group: inbound 22 (SSH), 80 (HTTP), and 443 (HTTPS), all outbound
- IAM role + instance profile for the instance, with (currently disabled —
  commented out in `iam.tf` — because the deploying AWS role lacks
  `iam:TagRole`/`iam:TagInstanceProfile`; re-enable once those permissions
  are granted):
  - `AmazonSSMManagedInstanceCore` (Session Manager access without SSH)
  - `CloudWatchAgentServerPolicy`
- EC2 instance (latest Amazon Linux 2023, `t3.micro` by default) with
  `user_data` that installs and starts nginx, IMDSv2 enforced, encrypted
  gp3 root volume
- A systemd-managed `iptables` NAT rule redirecting inbound `:80`/`:443` to
  `var.nginx_http_port` / `var.nginx_https_port` (default `8080`/`8443`, the
  host ports docker compose publishes nginx on) — lets the instance be
  reached on the standard HTTP/HTTPS ports without running dockerd/nginx
  as root

## Prerequisites

- AWS credentials in the environment with permissions to manage VPC, EC2,
  and IAM resources (see "Usage" below).
- **A pre-allocated Elastic IP, created by hand before the first `apply`.**
  This module deliberately does *not* create the Elastic IP itself (see
  `eip.tf`) — it only looks up and associates one you already have.
  Allocate it once, in the same region as `var.aws_region`:

  **Console:** EC2 → Network & Security → **Elastic IPs** → *Allocate
  Elastic IP address* → Allocate. Note the **Allocation ID**
  (`eipalloc-...`) shown afterward.

  **CLI:**
  ```bash
  aws ec2 allocate-address --domain vpc --region eu-central-1 \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=nginx-icap-module-eip}]'
  ```
  Note the `AllocationId` from the output.

  Then point `terraform.tfvars` at it (see `elastic_ip_allocation_id` in
  `variables.tf`):
  ```hcl
  elastic_ip_allocation_id = "eipalloc-xxxxxxxxxxxxxxxxx"
  ```
  This only needs to be done once — the same address is re-associated with
  a fresh instance on every subsequent `destroy`/`apply` cycle.

- **A DNS A record pointing at that Elastic IP**. Let's Encrypt's
  HTTP-01 challenge requires a real, publicly-resolvable domain name — it
  will not issue a certificate for the instance's own AWS-assigned
  hostname (`*.compute.amazonaws.com` is policy-blocked by the CA), nor
  for a bare IP address. In whichever DNS provider hosts your domain
  (Route53, GoDaddy, etc.), add:

  | Type | Name                                         | Value                      |
  |------|----------------------------------------------|-----------------------------|
  | A    | e.g. `icap` (→ `icaptest.reversinglabs.com`) | the Elastic IP's address (`terraform output -raw instance_public_ip`) |

  Confirm it's resolving before issuing a cert:
  ```bash
  dig +short icaptest.reversinblabs.com
  ```

## Usage

```bash
cd terraform/ec2-nginx
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum lock down ssh_cidr_blocks to your IP,
# and set elastic_ip_allocation_id (see "Prerequisites" above)

terraform init
terraform plan
terraform apply
```

Requires AWS credentials in the environment (`aws configure`,
`AWS_PROFILE`, etc.) with permissions to manage VPC, EC2, and IAM
resources.

For more information access AWS console @ https://reversinglabs.awsapps.com/start/#/

Once applied:

Check AWS identity
```bash
aws sts get-caller-identity
```

```bash
terraform output nginx_url        # http://<public-ip>
curl "$(terraform output -raw nginx_url)"
```

If no `key_name` is set, reach the instance via SSM instead of SSH:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

After apply, get the key with:                                                                                                                                                                                                   
```bash
terraform output -raw ssh_private_key_pem > key.pem && chmod 600 key.pem                                                                                                                                                         

# or just use the file Terraform already wrote:                                                                                                                                                                                  
terraform output -raw ssh_private_key_path                                                                                                                                                                                       
terraform output ssh_command gives you the exact command to connect. 

```

Connect to instance using following command
```bash
ssh -i nginx-icap-module-key.pem -o StrictHostKeyChecking=no ec2-user@"$(terraform output -raw instance_public_dns)"
```

The instance sits behind a pre-existing Elastic IP (see `eip.tf`) that stays
the same across `destroy`/`apply` cycles, but each cycle boots a brand-new
instance with a fresh SSH host key. `StrictHostKeyChecking=accept-new` only
auto-trusts hosts your machine has *never* seen before — for an address it
already has a (now-stale) key for, from the last cycle, it'll refuse to
connect instead. If that happens, clear the old entry first:
```bash
ssh-keygen -R "$(terraform output -raw instance_public_dns)"
ssh-keygen -R "$(terraform output -raw instance_public_ip)"
```

## Teardown

```bash
terraform destroy
```

## Notes / things to adjust for production use

- `ssh_cidr_blocks`, `http_cidr_blocks`, and `https_cidr_blocks` default to
  `0.0.0.0/0` for a quick demo — restrict all three before using this
  beyond a sandbox.
- Port 80 is briefly opened to `0.0.0.0/0` during every `apply` regardless
  of `http_cidr_blocks` — `docker-compose-certbot.yml`'s "certificates"
  service (part of the `docker compose up` in `ec2.tf`'s last provisioner)
  needs Let's Encrypt's HTTP-01 validation servers, which don't come from
  an IP `http_cidr_blocks` would predict, to reach it. A provisioner in
  `ec2.tf` revokes that wide-open rule and (re)applies `http_cidr_blocks`
  immediately once `docker compose up` finishes, so the security group
  ends the apply matching `terraform.tfvars` — but the instance is briefly
  reachable on `:80` from anywhere while provisioning is still running.
- `var.nginx_http_port` / `var.nginx_https_port` must match `NGINX_PORT` /
  `NGINX_HTTPS_PORT` in whichever `harness/.env-*` file the deployed `.env`
  symlink points to — the NAT rules redirect `:80`/`:443` to these ports, so
  a mismatch means the corresponding port won't reach nginx.
- The bundled nginx TLS cert is self-signed (see `harness/nginx.docker.conf`)
  — expect a browser warning / need `curl -k` on `:443` until a real cert is
  wired in.
- No remote state backend is configured; add an `S3` + `DynamoDB` (or
  Terraform Cloud) backend before using this for anything shared/long-lived.
- Single AZ, single instance, no ALB/ASG — this is a minimal demo, not a
  production topology.
- `user_data.sh.tpl` installs the `nginx` OS package but never starts it as
  a systemd service — the module actually runs inside the Docker stack
  (`docker compose`), not via the host's own nginx.