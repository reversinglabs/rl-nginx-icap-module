locals {
  common_tags = merge(
    {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Owner       = "Integrations"
      Environment = "Trial"
      Service     = "SpectraAnalyze"
      Usage       = "Generic"
      Customer    = "Internal"
    },
    var.tags
  )
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-subnet"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Allow inbound SSH, HTTP, HTTPS, and Grafana, all outbound"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-web-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = length(var.ssh_cidr_blocks)
  security_group_id = aws_security_group.web.id
  description       = "SSH"
  cidr_ipv4         = var.ssh_cidr_blocks[count.index]
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count             = length(var.http_cidr_blocks)
  security_group_id = aws_security_group.web.id
  description       = "HTTP"
  cidr_ipv4         = var.http_cidr_blocks[count.index]
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count             = length(var.https_cidr_blocks)
  security_group_id = aws_security_group.web.id
  description       = "HTTPS"
  cidr_ipv4         = var.https_cidr_blocks[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "grafana" {
  count             = length(var.grafana_cidr_blocks)
  security_group_id = aws_security_group.web.id
  description       = "Grafana"
  cidr_ipv4         = var.grafana_cidr_blocks[count.index]
  from_port         = 3000
  to_port            = 3000
  ip_protocol       = "tcp"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = local.common_tags
}