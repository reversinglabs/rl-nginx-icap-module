variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Name prefix applied to all resources (used in tags and Name attributes)."
  type        = string
  default     = "nginx-icap-module-demo"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet the instance is launched into."
  type        = string
  default     = "10.20.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the public subnet. Leave null to let Terraform pick the first AZ in the region."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "bootstrap_app" {
  description = "Whether to run terraform_data.deploy — the provisioner that opens port 80 temporarily, symlinks .env to .env-rl-aws, and runs `docker compose up --build` (Let's Encrypt cert + the app itself). Set to false to stand up just the VPC/EC2/IAM/EIP plumbing (e.g. while diagnosing IAM permissions) without also bringing the docker stack up. Flipping this back to true on a later apply runs the deploy normally — nothing here is destructive to skip."
  type        = bool
  default     = true
}

variable "elastic_ip_allocation_id" {
  description = "Allocation ID (eipalloc-...) of a pre-existing Elastic IP to associate with the instance. Deliberately looked up, not created, by this module (see eip.tf) — the stack gets torn down and re-applied between sessions to save cost, and Terraform creating/releasing the address on every such cycle would break any DNS record pointed at it. Allocate it once by hand (AWS Console -> EC2 -> Elastic IPs -> Allocate Elastic IP address, or `aws ec2 allocate-address --domain vpc`) and set this to its allocation ID."
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to attach for SSH access. Leave null to launch without one (use SSM Session Manager instead)."
  type        = string
  default     = null
}

variable "ssh_private_key_path" {
  description = "Local path to the private key matching var.key_name, used to SSH in and copy the repo. Required only when var.key_name is set — when it's left null Terraform generates its own key pair and private key file, so this isn't needed."
  type        = string
  default     = null
}

variable "repo_path" {
  description = "Local path to the repo to copy to the instance's home directory (/home/ec2-user/<repo dir name>). Relative paths are resolved against this Terraform module's directory."
  type        = string
  default     = "../.."
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed to reach the instance on port 22. Restrict this to your own IP in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_cidr_blocks" {
  description = "CIDR blocks allowed to reach the instance on port 80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "https_cidr_blocks" {
  description = "CIDR blocks allowed to reach the instance on port 443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "nginx_http_port" {
  description = "Host port nginx is published on by docker compose (NGINX_PORT in harness/.env). Inbound traffic on 80 is NAT-redirected to this port so the instance is reachable on the standard HTTP port without running nginx/dockerd as root on 80."
  type        = number
  default     = 8080
}

variable "nginx_https_port" {
  description = "Host port nginx's HTTPS listener is published on by docker compose (NGINX_HTTPS_PORT in harness/.env). Inbound traffic on 443 is NAT-redirected to this port, same as var.nginx_http_port for HTTP."
  type        = number
  default     = 8443
}

variable "nginx_plus_s3_bucket" {
  description = "S3 bucket the instance pulls its NGINX Plus install package(s) and license from, via its IAM instance profile (see iam.tf). Expected layout: 'versions/' holds the .deb(s) matching NGINX_PLUS_DEB, 'license/' holds the .jwt matching the basename of NGINX_PLUS_LICENSE, both in whichever harness/.env-* file the deployed .env symlink points to. Synced to ~/nginx/versions and ~/nginx/license on the instance."
  type        = string
  default     = "rl-nginx-plus-setup"
}

variable "grafana_cidr_blocks" {
  description = "CIDR blocks allowed to reach Grafana on port 3000."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}