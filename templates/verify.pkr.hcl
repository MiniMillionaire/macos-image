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

variable "expected_build" {
  type = string
}

variable "expected_xcode_version" {
  type    = string
  default = ""
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "verify" {
  vm_name            = var.vm_name
  headless           = true
  recovery_partition = "keep"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "5m"
}

build {
  sources = ["source.tart-cli.verify"]

  provisioner "file" {
    source      = "scripts/guest/user-tcc-database.sh"
    destination = "/tmp/macos-image-user-tcc-database.sh"
  }

  provisioner "shell" {
    timeout = "5m"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_XCODE_VERSION=${var.expected_xcode_version}",
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_USERNAME=${var.guest_username}",
      "IMAGE_PROFILE=${var.profile}",
    ]
    script = "scripts/guest/verify-image.sh"
  }
}
