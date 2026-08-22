data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name_prefix}-host"
  assume_role_policy   = data.aws_iam_policy_document.assume_ec2.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "artifact_read" {
  statement {
    sid       = "ListArtifactBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.artifact_bucket_arn]
  }

  statement {
    sid    = "ReadArtifactObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${var.artifact_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "artifact_read" {
  name   = "${var.name_prefix}-artifact-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.artifact_read.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-host"
  role = aws_iam_role.this.name

  tags = var.tags
}

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # The subnet disables automatic public-IP assignment. The instance's only
  # public IPv4 address is managed separately through aws_eip_association.
  monitoring = false

  user_data                   = templatefile("${path.module}/user_data.sh.tftpl", {})
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_size_gib
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-host"
  })
}

resource "aws_eip" "this" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-host"
  })
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = aws_instance.this.id
}
