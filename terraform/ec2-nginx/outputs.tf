output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = aws_internet_gateway.this.id
}

output "security_group_id" {
  description = "ID of the security group attached to the instance."
  value       = aws_security_group.web.id
}

output "instance_id" {
  description = "ID of the EC2 instance."
  value       = aws_instance.web.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance — the pre-existing Elastic IP (var.elastic_ip_allocation_id), which stays the same across destroy/apply cycles unlike the instance's own ephemeral address. Point any DNS A record (e.g. for Let's Encrypt) at this."
  value       = data.aws_eip.web.public_ip
}

output "elastic_ip_allocation_id" {
  description = "Allocation ID of the Elastic IP in use (echoes var.elastic_ip_allocation_id)."
  value       = data.aws_eip.web.id
}

output "instance_public_dns" {
  description = "AWS-style public DNS name for the Elastic IP, e.g. ec2-3-127-146-157.eu-central-1.compute.amazonaws.com. Deliberately built from the EIP (data.aws_eip.web) via AWS's fixed naming pattern rather than read from aws_instance.web.public_dns: that attribute is captured when the instance is created, *before* aws_eip_association.web runs, so within the same apply it lags behind and shows the instance's ephemeral address until a separate refresh. Informational only either way — unusable for Let's Encrypt, since *.compute.amazonaws.com is policy-blocked from issuance."
  value = "ec2-${replace(data.aws_eip.web.public_ip, ".", "-")}.${var.aws_region == "us-east-1" ? "compute-1.amazonaws.com" : "${var.aws_region}.compute.amazonaws.com"}"
}

output "nginx_url" {
  description = "URL to reach the nginx welcome page once boot/user-data has finished."
  value       = "http://${data.aws_eip.web.public_ip}"
}

output "nginx_https_url" {
  description = "HTTPS URL to reach nginx once boot/user-data has finished. Cert is self-signed, so callers need -k/--insecure (curl) or equivalent."
  value       = "https://${data.aws_eip.web.public_ip}"
}

output "ssh_key_name" {
  description = "Name of the EC2 key pair attached to the instance."
  value       = local.ssh_key_name
}

output "ssh_public_key_openssh" {
  description = "OpenSSH-format public key. Null if var.key_name was supplied (Terraform didn't generate a key)."
  value       = var.key_name == null ? tls_private_key.generated[0].public_key_openssh : null
}

output "ssh_private_key_pem" {
  description = "PEM-encoded private key. Null if var.key_name was supplied (Terraform didn't generate a key). Also written to ssh_private_key_path."
  value       = var.key_name == null ? tls_private_key.generated[0].private_key_pem : null
  sensitive   = true
}

output "ssh_private_key_path" {
  description = "Local path to the generated PEM private key file. Null if var.key_name was supplied."
  value       = var.key_name == null ? local_sensitive_file.private_key[0].filename : null
}

output "ssh_command" {
  description = "Ready-to-run SSH command using the generated (or supplied) key."
  value       = "ssh -i ${var.key_name == null ? local_sensitive_file.private_key[0].filename : "<path to your ${local.ssh_key_name} key>"} ec2-user@${data.aws_eip.web.public_ip}"
}