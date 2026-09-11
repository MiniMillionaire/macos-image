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

source "tart-cli" "native" {
  vm_name            = var.vm_name
  headless           = true
  disable_vnc        = true
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
  recovery_partition = "keep"
  run_extra_args = [
    "--provisioning-opts=fullName=${var.guest_username},username=${var.guest_username},password=${var.guest_password},logsInAutomatically=true,enablesRemoteLogin=true",
  ]
}

build {
  sources = ["source.tart-cli.native"]

  provisioner "shell" {
    timeout = "5m"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
    ]
    script = "scripts/guest/prepare-native.sh"
  }
}
