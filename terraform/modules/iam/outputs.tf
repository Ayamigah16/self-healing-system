output "ec2_instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}

output "lambda_exec_role_arn" {
  value = aws_iam_role.lambda_exec.arn
}

output "ec2_instance_role_arn" {
  value = aws_iam_role.ec2_instance.arn
}
