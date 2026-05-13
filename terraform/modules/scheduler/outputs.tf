output "role_arn" {
  description = "IAM role assumed by EventBridge Scheduler."
  value       = aws_iam_role.scheduler.arn
}

output "start_schedule_name" {
  description = "Name of the start schedule."
  value       = aws_scheduler_schedule.start.name
}

output "stop_schedule_name" {
  description = "Name of the stop schedule."
  value       = aws_scheduler_schedule.stop.name
}

output "enabled" {
  description = "Whether the schedules are currently ENABLED."
  value       = var.enabled
}
