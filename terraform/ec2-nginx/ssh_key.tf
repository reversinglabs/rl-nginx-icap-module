resource "tls_private_key" "generated" {
  count     = var.key_name == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  count      = var.key_name == null ? 1 : 0
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.generated[0].public_key_openssh

  tags = local.common_tags
}

resource "local_sensitive_file" "private_key" {
  count           = var.key_name == null ? 1 : 0
  filename        = "${path.module}/${var.project_name}-key.pem"
  content         = tls_private_key.generated[0].private_key_pem
  file_permission = "0600"
}

locals {
  ssh_key_name = coalesce(var.key_name, try(aws_key_pair.generated[0].key_name, null))

  # Private key used by the repo-copy provisioner: the one Terraform just
  # generated, or the one supplied for an existing key_name.
  ssh_private_key_path = var.key_name == null ? local_sensitive_file.private_key[0].filename : var.ssh_private_key_path

  repo_dest_dir = basename(abspath("${path.module}/${var.repo_path}"))
}
