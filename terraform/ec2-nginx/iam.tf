data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  # No tags: the deploying role lacks iam:TagRole, so tagging this
  # resource fails at creation. Add tags = local.common_tags back once
  # iam:TagRole/iam:UntagRole are granted.
}

# resource "aws_iam_role_policy_attachment" "ssm_core" {
#  role       = aws_iam_role.ec2.name
#  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# }

# resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
#  role       = aws_iam_role.ec2.name
#  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
# }

# Lets the instance pull its own NGINX Plus install package + license
# straight from S3 (via `aws s3 sync`, run on the instance in ec2.tf) rather
# than relying on the operator's local credentials to push them over SSH.
data "aws_iam_policy_document" "nginx_plus_s3_read" {
  statement {
    sid       = "ListBucketPrefixes"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.nginx_plus_s3_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["versions/*", "license/*"]
    }
  }

  statement {
    sid    = "GetObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "arn:aws:s3:::${var.nginx_plus_s3_bucket}/versions/*",
      "arn:aws:s3:::${var.nginx_plus_s3_bucket}/license/*",
    ]
  }
}

resource "aws_iam_role_policy" "nginx_plus_s3_read" {
  name   = "${var.project_name}-nginx-plus-s3-read"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.nginx_plus_s3_read.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name

  # No tags: the deploying role lacks iam:TagInstanceProfile, so tagging
  # this resource fails at creation. Add tags = local.common_tags back
  # once iam:TagInstanceProfile/iam:UntagInstanceProfile are granted.
}