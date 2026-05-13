variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "enabled" {
  description = "Master switch — when false, both schedules are created in DISABLED state and the IAM role still exists (so flipping back is a one-knob toggle, not a recreate)."
  type        = bool
  default     = true
}

variable "instance_id" {
  description = "EC2 instance ID to start / stop."
  type        = string
}

variable "instance_arn" {
  description = "EC2 instance ARN — used to scope the IAM policy to this single instance."
  type        = string
}

variable "timezone" {
  description = "IANA timezone for the schedules (e.g. Australia/Sydney)."
  type        = string
}

variable "start_cron" {
  description = "cron(...) expression for the start schedule."
  type        = string
}

variable "stop_cron" {
  description = "cron(...) expression for the stop schedule."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
