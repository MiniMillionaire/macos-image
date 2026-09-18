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

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "desktop" {
  vm_name            = var.vm_name
  headless           = true
  recovery_partition = "keep"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "5m"
  boot_wait          = "90s"
  boot_key_interval  = "150ms"
  boot_command = [
    "<leftCommandOn><leftOptionOn><spacebar><leftOptionOff><leftCommandOff><wait3s>",
    "<leftCommandOn><leftOptionOn>w<leftOptionOff><leftCommandOff><wait10s>",
  ]
}

build {
  sources = ["source.tart-cli.desktop"]

  provisioner "shell" {
    timeout          = "2m"
    environment_vars = ["GUEST_USERNAME=${var.guest_username}"]
    script           = "scripts/guest/clean-desktop.sh"
  }
}
