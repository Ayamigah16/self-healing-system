variable "name_prefix"          { type = string }
variable "suffix"               { type = string }
variable "alert_email"          { type = string }
variable "region"               { type = string }
variable "account_id"           { type = string }
variable "asg_name"             { type = string }
variable "lambda_exec_role_arn" { type = string }
variable "asg_max_size"         { type = number }
