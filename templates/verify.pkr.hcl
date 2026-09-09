packer {
  required_version = ">= 1.14.0, < 2.0.0"

  required_plugins {
    tart = {
      version = "= 1.21.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

variable "profile" {
  type = string
}

variable "expected_version" {
  type = string
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "verify" {
  vm_name      = var.vm_name
  headless     = true
  ssh_username = var.guest_username
  ssh_password = var.guest_password
  ssh_timeout  = "5m"
}

build {
  sources = ["source.tart-cli.verify"]

  provisioner "shell" {
    environment_vars = [
      "EXPECTED_VERSION=${var.expected_version}",
      "IMAGE_PROFILE=${var.profile}",
    ]
    script = "scripts/guest/verify-image.sh"
  }
}

