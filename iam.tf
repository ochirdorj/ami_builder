# IAM role for the builder instance
# Needs SSM access so we can poll install completion without SSH

resource "aws_iam_role" "ami_builder" {
  name = "${local.resource_name_prefix}-ami-builder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    ManagedBy = "Terraform"
    Project   = var.project
  }
}

# SSM access — lets us run commands without SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ami_builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ami_builder" {
  name = "${local.resource_name_prefix}-ami-builder-profile"
  role = aws_iam_role.ami_builder.name
}
