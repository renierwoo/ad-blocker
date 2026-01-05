# -----------------------------------------------------------------------------
# VPC & Subnets
# -----------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "ad_blocker_ec2" {
  description = "Ad blocker EC2 instance security group"
  name        = "ad-blocker-ec2"

  tags = {
    Name = "ad-blocker-ec2"
  }

  vpc_id = data.aws_vpc.default.id
}

#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "ad_blocker_ec2" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1" # semantically equivalent to all ports
  security_group_id = aws_security_group.ad_blocker_ec2.id
}

resource "aws_security_group" "ad_blocker_efs" {
  description = "Ad blocker EFS security group"
  name        = "ad-blocker-efs"

  tags = {
    Name = "ad-blocker-efs"
  }

  vpc_id = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "ad_blocker_efs" {
  description                  = "Allow inbound traffic from ad-blocker-ec2"
  from_port                    = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.ad_blocker_ec2.id
  security_group_id            = aws_security_group.ad_blocker_efs.id
  to_port                      = 2049
}

# -----------------------------------------------------------------------------
# EFS
# -----------------------------------------------------------------------------
resource "aws_efs_file_system" "ad_blocker" {
  creation_token   = "ad-blocker"
  encrypted        = true
  performance_mode = "generalPurpose"

  tags = {
    Name = "ad-blocker"
  }

  throughput_mode = "bursting"
}

resource "aws_efs_mount_target" "ad_blocker" {
  for_each = toset(data.aws_subnets.default.ids)

  file_system_id  = aws_efs_file_system.ad_blocker.id
  subnet_id       = each.value
  security_groups = [aws_security_group.ad_blocker_efs.id]
}

# -----------------------------------------------------------------------------
# AMI
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

# -----------------------------------------------------------------------------
# IAM Role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ad_blocker_assume_role" {
  version   = "2012-10-17"
  policy_id = "ad_blocker_assume_role_policy"

  statement {
    sid    = "AllowEC2AssumeRole"
    effect = "Allow"

    principals {
      identifiers = ["ec2.amazonaws.com"]
      type        = "Service"
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ad_blocker" {
  assume_role_policy = data.aws_iam_policy_document.ad_blocker_assume_role.json
  description        = "Ad blocker EC2 instance IAM role"
  name               = "ad-blocker-ec2"

  tags = {
    Name = "ad-blocker-ec2"
  }
}

resource "aws_iam_role_policy_attachment" "ad_blocker_ssm_readonly" {
  role       = aws_iam_role.ad_blocker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "ad_blocker_ssm_core" {
  role       = aws_iam_role.ad_blocker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ad_blocker" {
  version   = "2012-10-17"
  policy_id = "ad_blocker_policy"

  statement {
    sid       = "SecretsManagerAccess"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ad_blocker.arn]
  }
}

resource "aws_iam_role_policy" "ad_blocker" {
  name   = "ad-blocker"
  role   = aws_iam_role.ad_blocker.name
  policy = data.aws_iam_policy_document.ad_blocker.json
}

# -----------------------------------------------------------------------------
# IAM Instance Profile
# -----------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ad_blocker" {
  name = "ad-blocker-ec2"
  role = aws_iam_role.ad_blocker.name

  tags = {
    Name = "ad-blocker-ec2"
  }
}

# -----------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------
#trivy:ignore:AVD-AWS-0098
resource "aws_secretsmanager_secret" "ad_blocker" {
  description = "Ad blocker secrets"
  name        = "ad-blocker"

  tags = {
    Name = "ad-blocker"
  }
}

resource "aws_secretsmanager_secret_version" "ad_blocker" {
  secret_id = aws_secretsmanager_secret.ad_blocker.id

  secret_string = jsonencode({
    warp_token = var.warp_connector_token
  })
}

# -----------------------------------------------------------------------------
# Launch Template
# -----------------------------------------------------------------------------
resource "aws_launch_template" "ad_blocker" {
  description   = "Ad blocker Auto Scaling Group launch template"
  ebs_optimized = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ad_blocker.name
  }

  image_id                             = data.aws_ssm_parameter.al2023_arm.value
  instance_initiated_shutdown_behavior = "terminate"

  # instance_market_options {
  #   market_type = "spot"

  #   spot_options {
  #     max_price = "0.0096"
  #   }
  # }

  instance_type = "t4g.nano"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  name_prefix = "ad-blocker"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ad_blocker_ec2.id]
  }

  #   tag_specifications {
  #     resource_type = "instance"

  #     tags = {
  #       Name = "ad-blocker"
  #     }
  #   }

  user_data = base64encode(
    templatefile("${path.module}/assets/user-data.tpl", {
      efs_id   = aws_efs_file_system.ad_blocker.id
      region   = var.aws_default_region
      vpc_cidr = data.aws_vpc.default.cidr_block
    })
  )
}

# -----------------------------------------------------------------------------
# Auto Scaling Group
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "ad_blocker" {
  name               = "ad-blocker"
  max_size           = 1
  min_size           = 1
  capacity_rebalance = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # 100% Spot
      spot_allocation_strategy                 = "capacity-optimized"
      spot_max_price                           = "0.0096"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ad_blocker.id
        version            = "$Latest"
      }

      override {
        instance_type     = "t4g.nano"
        weighted_capacity = 1
      }

      override {
        instance_type     = "t4g.micro"
        weighted_capacity = 2
      }
    }
  }

  health_check_grace_period = 300
  health_check_type         = "EC2"
  desired_capacity          = 1
  force_delete              = false
  vpc_zone_identifier       = data.aws_subnets.default.ids

  tag {
    key                 = "Name"
    value               = "ad-blocker"
    propagate_at_launch = true
  }

  wait_for_capacity_timeout = "5m"

  instance_refresh {
    strategy = "Rolling"
  }
}
