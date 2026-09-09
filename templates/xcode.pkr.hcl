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

variable "xcode_archive" {
  type = string
}

variable "xcode_components" {
  type    = list(string)
  default = []
}

variable "disk_size_gb" {
  type    = number
  default = 180
}

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "xcode" {
  vm_name            = var.vm_name
  headless           = true
  disk_size_gb       = var.disk_size_gb
  recovery_partition = "relocate"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
}

build {
  sources = ["source.tart-cli.xcode"]

  provisioner "file" {
    source      = "data/Brewfile.xcode"
    destination = "/tmp/Brewfile.xcode"
  }

  provisioner "file" {
    source      = var.xcode_archive
    destination = "/Users/${var.guest_username}/Downloads/Xcode_${var.xcode_version}.xip"
  }

  provisioner "shell" {
    environment_vars = [
      "GUEST_USERNAME=${var.guest_username}",
      "XCODE_COMPONENTS=${join(",", var.xcode_components)}",
      "XCODE_VERSION=${var.xcode_version}",
    ]
    scripts = [
      "scripts/guest/install-xcode.sh",
      "scripts/guest/install-mobile-tools.sh",
      "scripts/guest/verify-xcode.sh",
    ]
  }
}
