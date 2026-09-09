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

source "tart-cli" "prepare" {
  vm_name            = var.vm_name
  headless           = true
  recovery_partition = "keep"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "5m"
}

build {
  sources = ["source.tart-cli.prepare"]

  provisioner "shell" {
    inline = [
      "sudo languagesetup -langspec 0",
      "sudo nvram prev-lang:kbd=en-US:0",
    ]
  }
}
