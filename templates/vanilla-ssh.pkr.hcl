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

variable "expected_version" {
  type = string
}

variable "expected_build" {
  type = string
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "vanilla" {
  vm_name            = var.vm_name
  headless           = true
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
  recovery_partition = "keep"
}

build {
  sources = ["source.tart-cli.vanilla"]

  provisioner "shell" {
    timeout = "5m"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
    ]
    script = "scripts/guest/configure-vanilla.sh"
  }

  provisioner "shell" {
    script  = "scripts/guest/install-command-line-tools.sh"
    timeout = "45m"
  }

  provisioner "shell" {
    timeout          = "2m"
    environment_vars = ["GUEST_USERNAME=${var.guest_username}"]
    script           = "scripts/guest/clean-desktop.sh"
  }
}
