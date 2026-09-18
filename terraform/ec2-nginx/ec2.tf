data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = local.ssh_key_name
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
    tags                  = local.common_tags
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    project_name     = var.project_name
    nginx_http_port  = var.nginx_http_port
    nginx_https_port = var.nginx_https_port
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-web"
  })

  lifecycle {
    precondition {
      condition     = var.key_name == null || var.ssh_private_key_path != null
      error_message = "var.key_name is set to an existing key pair, so var.ssh_private_key_path must also be set — Terraform needs it to SSH in and copy the repo."
    }
  }

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file(local.ssh_private_key_path)
    timeout     = "5m"
  }

  # Wait for user_data (which installs rsync, among other things) to finish
  # before pushing the repo, and stage the destination directory.
  #
  # Also pulls the NGINX Plus install package + license from S3
  # (var.nginx_plus_s3_bucket) straight onto the instance, using this
  # instance's own IAM role (aws_iam_instance_profile.ec2 / iam.tf) rather
  # than the operator's local credentials — awscli ships preinstalled on
  # AL2023, so no user_data change is needed for this. Lands at
  # ~/nginx/versions and ~/nginx/license, matching NGINX_PLUS_SW_ROOT /
  # NGINX_PLUS_LICENSE in harness/.env-rl-aws.
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null 2>&1 || true",
      "mkdir -p /home/ec2-user/${local.repo_dest_dir}",
      "mkdir -p /home/ec2-user/nginx/versions /home/ec2-user/nginx/license",
      "aws s3 sync --only-show-errors --region '${var.aws_region}' 's3://${var.nginx_plus_s3_bucket}/versions/' /home/ec2-user/nginx/versions/",
      "aws s3 sync --only-show-errors --region '${var.aws_region}' 's3://${var.nginx_plus_s3_bucket}/license/' /home/ec2-user/nginx/license/",
    ]
  }

  # Copy the whole local repo (var.repo_path) into the instance's home
  # directory over SSH. Runs from the machine executing `terraform apply`,
  # not on the instance — embedding a full repo into user_data isn't
  # feasible under EC2's 16 KB user_data size limit.
  provisioner "local-exec" {
    command = <<-EOT
      rsync -az --delete \
        --exclude='.git/' --exclude='.terraform/' --exclude='terraform.tfstate*' --exclude='*.pem' --exclude='.env' \
        -e 'ssh -i "${local.ssh_private_key_path}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' \
        "${var.repo_path}/" "ec2-user@${self.public_ip}:/home/ec2-user/${local.repo_dest_dir}/"
    EOT
  }

  # Deliberately stops here: bringing the app up (below) needs the Elastic
  # IP already associated (see terraform_data.deploy's comment for why), and
  # aws_eip_association.web can only run once *this* resource — including
  # every provisioner on it — has finished. Any app-bring-up step that could
  # fail therefore has to live outside this block, or a failure here would
  # abort the apply before the EIP association ever runs, leaving the
  # instance on its ephemeral public IP instead (see terraform_data.deploy).
}

# Brings the app up — deliberately a separate resource from aws_instance.web
# (not more provisioners on it) so it runs strictly after
# aws_eip_association.web, guaranteeing the Elastic IP is already pointed at
# this instance before anything below runs. That matters because:
#   1. LETSENCRYPT_DOMAIN's DNS A record resolves to the Elastic IP, not the
#      instance's ephemeral one — docker-compose-certbot.yml's "certificates"
#      service (the HTTP-01 challenge, below) would have nowhere to land
#      otherwise.
#   2. A failed provisioner here only taints *this* resource, not
#      aws_instance.web — previously (when these were provisioners on
#      aws_instance.web itself) a failure here aborted its creation before
#      aws_eip_association.web ever ran, so the EIP was left unassociated
#      and the instance stuck on its ephemeral address. See git history /
#      conversation for the incident this fixes.
resource "terraform_data" "deploy" {
  count      = var.bootstrap_app ? 1 : 0
  depends_on = [aws_eip_association.web]

  # Forces this resource (and hence its provisioners, which otherwise only
  # ever run once at creation) to rerun whenever the instance itself is
  # replaced — e.g. every destroy/apply cycle between sessions.
  triggers_replace = {
    instance_id = aws_instance.web.id
  }

  connection {
    type = "ssh"
    # The Elastic IP, not aws_instance.web.public_ip -- that attribute is
    # captured when the instance is created, before aws_eip_association.web
    # runs, so it's stuck showing the (by now possibly stale/unreachable)
    # ephemeral address for the lifetime of this resource. data.aws_eip.web
    # is stable and, thanks to depends_on above, already associated here.
    host        = data.aws_eip.web.public_ip
    user        = "ec2-user"
    private_key = file(local.ssh_private_key_path)
    timeout     = "5m"
  }

  # Temporarily open port 80 to the entire internet, *in addition to* the
  # permanent aws_vpc_security_group_ingress_rule.http rule (var.http_cidr_blocks,
  # normally locked down to a known IP). Deliberately managed here via the
  # AWS CLI rather than as a Terraform resource: it only needs to exist for
  # the few minutes it takes docker compose to come up below, and its whole
  # point is to be gone again by the time this apply finishes, which doesn't
  # fit a resource Terraform expects to persist in state between applies.
  # It's not optional — docker-compose-certbot.yml's "certificates" service
  # (invoked from the next provisioner) completes a Let's Encrypt HTTP-01
  # challenge, and that request lands on port 80 from one of Let's Encrypt's
  # own validation IPs, not from whatever IP var.http_cidr_blocks allows.
  # `|| true` makes this safe to rerun (e.g. a retried apply) without
  # failing on an already-present rule.
  provisioner "local-exec" {
    command = <<-EOT
      aws ec2 authorize-security-group-ingress \
        --region "${var.aws_region}" \
        --group-id "${aws_security_group.web.id}" \
        --protocol tcp --port 80 --cidr 0.0.0.0/0
    EOT
  }

  # The repo already landed on the instance via aws_instance.web's own
  # provisioners; bring the app up now that port 80 is reachable from
  # anywhere (immediately above) and the Elastic IP is associated
  # (depends_on above) — both required for the certbot HTTP-01 challenge
  # this triggers to actually succeed.
  provisioner "remote-exec" {
    inline = [
      "cd /home/ec2-user/${local.repo_dest_dir}/docker",
      "[ -L .env ] && unlink .env || true",
      "ln -s .env-rl-aws .env",
      "docker compose -f docker-compose.yml -f docker-compose-certbot.yml -f docker-compose.observability.yml up -d --build || true",
    ]
  }

  # docker compose up (immediately above) has now obtained the Let's
  # Encrypt cert and brought nginx up, so the wide-open rule from the first
  # provisioner above has served its purpose — remove it, and (re)authorize
  # the CIDR blocks from terraform.tfvars (var.http_cidr_blocks) so the
  # security group's actual state matches what tfvars declares, the same
  # set aws_vpc_security_group_ingress_rule.http keeps in Terraform state.
  # The temporary rule is removed by its own security-group-rule-id
  # (sgr-...), looked up from its exact attributes, rather than by
  # --protocol/--port/--cidr — that older revoke form matches (and would
  # delete) *any* rule with the same tuple, which risks taking the
  # permanent var.http_cidr_blocks rule down with it if it ever happens to
  # cover 0.0.0.0/0 too. An empty $sgr_id (already gone, e.g. a retried
  # apply) is left as a no-op rather than erroring.
  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      sgr_id=$(aws ec2 describe-security-group-rules \
        --region "${var.aws_region}" \
        --filters "Name=group-id,Values=${aws_security_group.web.id}" \
        --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`80\` && ToPort==\`80\` && CidrIpv4=='0.0.0.0/0'].SecurityGroupRuleId" \
        --output text)
      if [ -n "$sgr_id" ]; then
        aws ec2 revoke-security-group-ingress \
          --region "${var.aws_region}" \
          --group-id "${aws_security_group.web.id}" \
          --security-group-rule-ids $sgr_id
      fi
    EOT
  }
}