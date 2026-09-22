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

variable "xcode_version" {
  type = string
}

variable "xcode_excluded_platforms" {
  type    = list(string)
  default = []
}

variable "xcode_platforms" {
  type    = list(string)
  default = []
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "slim" {
  vm_name            = var.vm_name
  headless           = true
  recovery_partition = "keep"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
}

build {
  sources = ["source.tart-cli.slim"]

  provisioner "file" {
    source      = "scripts/guest/slim-xcode.py"
    destination = "/tmp/macos-image-slim-xcode.py"
  }

  provisioner "shell" {
    timeout = "2h"
    environment_vars = [
      "GUEST_USERNAME=${var.guest_username}",
      "XCODE_EXCLUDED_PLATFORMS=${join(",", var.xcode_excluded_platforms)}",
      "XCODE_PLATFORMS=${join(",", var.xcode_platforms)}",
      "XCODE_VERSION=${var.xcode_version}",
    ]
    scripts = [
      "scripts/guest/slim-xcode.sh",
      "scripts/guest/verify-xcode.sh",
    ]
  }
}
