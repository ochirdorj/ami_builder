locals {
  resource_name_prefix = "${var.project}-${var.environment}"
}

# ── BASE UBUNTU AMI (official Canonical) ──────────────────────────────────────
data "aws_ssm_parameter" "ubuntu_base" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

# ── TEMP SECURITY GROUP (SSH access during build) ─────────────────────────────
resource "aws_security_group" "ami_builder" {
  name        = "${local.resource_name_prefix}-ami-builder-sg"
  description = "Temporary SG for AMI builder instance"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound for package installs"
  }

  tags = {
    Name      = "${local.resource_name_prefix}-ami-builder-sg"
    ManagedBy = "Terraform"
    Project   = var.project
  }
}

# ── TEMP EC2 INSTANCE ─────────────────────────────────────────────────────────
resource "aws_instance" "ami_builder" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_base.value)
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.ami_builder.id]
  iam_instance_profile        = aws_iam_instance_profile.ami_builder.name
  associate_public_ip_address = false

  user_data_base64 = base64encode(file("${path.module}/install.sh"))

  # Wait for user-data to finish before snapshotting
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name      = "${local.resource_name_prefix}-ami-builder"
    ManagedBy = "Terraform"
    Project   = var.project
  }
}

# ── WAIT FOR INSTALL TO COMPLETE ──────────────────────────────────────────────
# Polls SSM until the install script writes "AMI install complete" to the log
resource "terraform_data" "wait_for_install" {
  depends_on = [aws_instance.ami_builder]

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting for AMI builder instance to complete install..."
      for i in $(seq 1 60); do
        STATUS=$(aws ssm send-command \
          --instance-id ${aws_instance.ami_builder.id} \
          --document-name "AWS-RunShellScript" \
          --parameters '{"commands":["grep -c \"AMI install complete\" /var/log/ami-install.log 2>/dev/null || echo 0"]}' \
          --query 'Command.CommandId' \
          --output text \
          --region ${var.aws_region} 2>/dev/null)

        # Skip iteration if SSM agent not ready yet
        if [ -z "$STATUS" ] || [ "$STATUS" = "None" ]; then
          echo "Attempt $i/60 — waiting for SSM agent..."
          sleep 30
          continue
        fi

        # Block until the command finishes (avoids reading empty InProgress output)
        aws ssm wait command-executed \
          --command-id "$STATUS" \
          --instance-id ${aws_instance.ami_builder.id} \
          --region ${var.aws_region} 2>/dev/null || true

        RESULT=$(aws ssm get-command-invocation \
          --command-id "$STATUS" \
          --instance-id ${aws_instance.ami_builder.id} \
          --region ${var.aws_region} \
          --query 'StandardOutputContent' \
          --output text 2>/dev/null || echo "0")

        if [ "$RESULT" = "1" ]; then
          echo "Install complete!"
          exit 0
        fi

        echo "Attempt $i/60 — still installing..."
        sleep 25
      done
      echo "Timeout waiting for install"
      exit 1
    EOF
  }
}

# ── CREATE AMI FROM INSTANCE ──────────────────────────────────────────────────
resource "aws_ami_from_instance" "runner" {
  depends_on              = [terraform_data.wait_for_install]
  name                    = "${local.resource_name_prefix}-runner-${formatdate("YYYYMMDD-HHmm", timestamp())}"
  source_instance_id      = aws_instance.ami_builder.id
  snapshot_without_reboot = false

  tags = {
    Name        = "${local.resource_name_prefix}-runner"
    ManagedBy   = "Terraform"
    Project     = var.project
    Environment = var.environment
    BaseAMI     = nonsensitive(data.aws_ssm_parameter.ubuntu_base.value)
  }

  lifecycle {
    create_before_destroy = true
    # timestamp() changes on every plan — ignore_changes prevents
    # the AMI from being recreated unless the instance itself changes
    ignore_changes = [name]
  }
}

# ── TERMINATE BUILDER INSTANCE ────────────────────────────────────────────────
resource "terraform_data" "terminate_builder" {
  depends_on = [aws_ami_from_instance.runner]

  provisioner "local-exec" {
    command = <<-EOF
      echo "Terminating AMI builder instance ${aws_instance.ami_builder.id}..."
      aws ec2 terminate-instances \
        --instance-ids ${aws_instance.ami_builder.id} \
        --region ${var.aws_region}
      echo "Waiting for instance to terminate..."
      aws ec2 wait instance-terminated \
        --instance-ids ${aws_instance.ami_builder.id} \
        --region ${var.aws_region}
      echo "Instance terminated."
    EOF
  }
}

# ── STORE AMI ID IN SSM PARAMETER ─────────────────────────────────────────────
# Makes it easy to reference across accounts / modules
resource "aws_ssm_parameter" "runner_ami" {
  depends_on  = [aws_ami_from_instance.runner]
  name        = "/${var.project}/${var.environment}/runner-ami-id"
  type        = "String"
  value       = aws_ami_from_instance.runner.id
  description = "Pre-baked GitHub Actions runner AMI"
  overwrite   = true

  tags = {
    ManagedBy = "Terraform"
    Project   = var.project
  }
}
