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

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "recovery" {
  vm_name            = var.vm_name
  recovery           = true
  recovery_partition = "keep"
  communicator       = "none"
  boot_command = [
    "<wait60s><right><right><enter>",
    "<wait10s><leftAltOn>T<leftAltOff>",
    "<wait10s>csrutil disable<enter>",
    "<wait10s>y<enter>",
    "<wait10s>${var.guest_password}<enter>",
    "<wait10s>csrutil status<enter>",
    "<wait5s>halt<enter>",
  ]
}

build {
  sources = ["source.tart-cli.recovery"]
}
