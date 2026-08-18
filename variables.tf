variable "environment" {
  description = "Deployment environment this stack represents."
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["sandbox", "staging", "production"], var.environment)
    error_message = "environment must be one of: sandbox, staging, production."
  }
}

variable "service_name" {
  description = "Logical service name used to label generated resources."
  type        = string
  default     = "hello-spacelift"
}
