variable "aws_default_region" {
  description = "The AWS default region to use."
  type        = string
  sensitive   = true
}

variable "warp_connector_token" {
  description = "The Warp connector token to use."
  type        = string
  sensitive   = true
}
