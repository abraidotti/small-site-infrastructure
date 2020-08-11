variable "root" {
  description = "Website root, e.g. example.com"
  type        = string
}

variable "redirect" {
  description = "Alias for root website, e.g. www.example.com"
  type        = string
}

variable "aws_profile" {
    type = string
}