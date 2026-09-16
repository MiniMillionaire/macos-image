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

variable "disk_size_gb" {
  type = number
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "resize" {
  vm_name            = var.vm_name
  headless           = true
  disable_vnc        = true
  disk_size_gb       = var.disk_size_gb
  recovery_partition = "relocate"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
  run_extra_args     = ["--no-audio", "--no-clipboard"]
}

build {
  sources = ["source.tart-cli.resize"]

  provisioner "shell" {
    timeout = "5m"
    environment_vars = ["TARGET_DISK_SIZE_GB=${var.disk_size_gb}"]
    script = "scripts/guest/verify-resize.sh"
  }
}
