output "devops_guru_enabled" {
  value = var.enable_devops_guru
}

output "notification_channel_id" {
  value = var.enable_devops_guru ? aws_devopsguru_notification_channel.main[0].id : null
}
