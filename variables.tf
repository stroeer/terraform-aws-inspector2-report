variable "function_name" {
  description = "The name of the Lambda function"
  type        = string
  default     = "security-data-collector"
}

variable "bucket_name" {
  description = "The name of the S3 bucket"
  type        = string
  default     = "security-lake"
}

variable "bucket_arn" {
  description = "The ARN of an already existing S3 bucket. Will create a bucket if not set."
  type        = string
  default     = null
}

variable "role_name" {
  description = "Name of the role that the lambda function can assume in each child account."
  type        = string
  default     = "WA-Optimization-Data-Multi-Account-Role"
}

variable "glue_table_name" {
  description = "The name of the Glue table"
  type        = string
  default     = "optimization_data"
}

variable "glue_role_arn" {
  description = "The ARN of the role that the Glue table can assume."
  type        = string
}
