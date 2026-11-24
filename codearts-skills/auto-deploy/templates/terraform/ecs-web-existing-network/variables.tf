variable "region" {
  type = string
}

variable "security_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "availability_zone" {
  type = string
}

variable "app_name" {
  type = string
}

variable "existing_vpc_id" {
  type = string
}

variable "existing_subnet_id" {
  type = string
}

variable "security_group_name" {
  type = string
}

variable "instance_name" {
  type = string
}

variable "instance_flavor_name" {
  type = string
}

variable "instance_image_name" {
  type        = string
  description = "Supports regular expression matching."
}

variable "system_disk_type" {
  type = string
}

variable "system_disk_size" {
  type = number
}

variable "keypair_name" {
  type = string
}

variable "keypair_public_key" {
  type      = string
  sensitive = true
}

variable "eip_type" {
  type = string
}

variable "bandwidth_name" {
  type = string
}

variable "bandwidth_size" {
  type = number
}

variable "bandwidth_share_type" {
  type = string
}

variable "bandwidth_charge_mode" {
  type = string
}

variable "ssh_cidr" {
  type = string
}

variable "app_port" {
  type = number
}

variable "app_public_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "open_http" {
  type    = bool
  default = true
}

variable "open_https" {
  type    = bool
  default = true
}
