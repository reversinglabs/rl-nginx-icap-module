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

# resource "aws_iam_role" "ec2" {
#  name               = "${var.project_name}-ec2-role"
#  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

# No tags: the deploying role lacks iam:TagRole, so tagging this
# resource fails at creation. Add tags = local.common_tags back once
# iam:TagRole/iam:UntagRole are granted.
# }

# resource "aws_iam_role_policy_attachment" "ssm_core" {
#  role       = aws_iam_role.ec2.name
#  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# }

# resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
#  role       = aws_iam_role.ec2.name
#  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
# }

# resource "aws_iam_instance_profile" "ec2" {
#  name = "${var.project_name}-ec2-profile"
#  role = aws_iam_role.ec2.name

# No tags: the deploying role lacks iam:TagInstanceProfile, so tagging
# this resource fails at creation. Add tags = local.common_tags back
# once iam:TagInstanceProfile/iam:UntagInstanceProfile are granted.
# }