locals {
  vpc_dns_resolver_cidr = "${cidrhost(var.vpc_cidr, 2)}/32"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.availability_zone
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id

  ingress = []
  egress  = []

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-default-deny"
  })
}

resource "aws_security_group" "edge" {
  name_prefix = "${var.name_prefix}-edge-"
  description = "Public web ingress and explicitly reviewed host egress"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-edge"
  })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.edge.id
  description       = "Public HTTP"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.edge.id
  description       = "Public HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.edge.id
  description       = "HTTPS egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.edge.id
  description       = "HTTP egress for package and ACME redirects"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.edge.id
  description       = "VPC resolver DNS over UDP"
  cidr_ipv4         = local.vpc_dns_resolver_cidr
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.edge.id
  description       = "VPC resolver DNS over TCP"
  cidr_ipv4         = local.vpc_dns_resolver_cidr
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "time_sync" {
  security_group_id = aws_security_group.edge.id
  description       = "Amazon Time Sync"
  cidr_ipv4         = "169.254.169.123/32"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
}
