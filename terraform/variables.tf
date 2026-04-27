variable "region" {
  description = "AWS region for all resources in this project."
  type        = string
  default     = "us-east-1"
}

variable "function_name" {
  description = "Name of the Stage 1 hello-world Lambda."
  type        = string
  default     = "lambda-hw-hello"
}

variable "ec2_invoker_role_name" {
  description = <<-EOT
    Name of the existing EC2 instance role that will be granted permission to
    invoke the Function URL. Must already exist (we reference it via a data
    block, we don't create it here).
  EOT
  type        = string
  default     = "apps-ec2-role"
}
