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

variable "ipsw_url" {
  type = string
}

variable "expected_version" {
  type = string
}

variable "expected_build" {
  type = string
}

variable "cpu_count" {
  type = number
}

variable "memory_gb" {
  type = number
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

source "tart-cli" "sequoia" {
  from_ipsw          = var.ipsw_url
  vm_name            = var.vm_name
  cpu_count          = var.cpu_count
  memory_gb          = var.memory_gb
  disk_size_gb       = var.disk_size_gb
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
  create_grace_time  = "30s"
  recovery_partition = "keep"
  boot_key_interval  = "100ms"

  boot_command = [
    "<wait60s><spacebar>",
    "<wait30s>italiano<esc>english<enter>",
    "<wait30s><click 'Select Your Country or Region'><wait5s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><tab><tab><spacebar><tab><tab><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s>CI User<tab>${var.guest_username}<tab>${var.guest_password}<tab>${var.guest_password}<tab><tab><spacebar><tab><tab><spacebar>",
    "<wait120s><leftAltOn><f5><leftAltOff>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><tab><tab>UTC<enter><leftShiftOn><tab><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><tab><spacebar><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><spacebar>",
    "<leftAltOn><f5><leftAltOff>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<enter>",
    "<wait10s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    "<wait10s><leftAltOn>q<leftAltOff>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>System Settings<enter>",
    "<wait10s><leftCtrlOn><f2><leftCtrlOff><right><right><right><down>Sharing<enter>",
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    "<wait10s><leftAltOn>q<leftAltOff>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<enter>",
    "<wait10s>sudo spctl --global-disable<enter>",
    "<wait10s>${var.guest_password}<enter>",
    "<wait10s><leftAltOn>q<leftAltOff>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>System Settings<enter>",
    "<wait10s><leftCtrlOn><f2><leftCtrlOff><right><right><right><down>Privacy & Security<enter>",
    "<wait10s><leftShiftOn><tab><tab><tab><tab><tab><tab><tab><leftShiftOff>",
    "<wait10s><down><wait1s><down><wait1s><enter>",
    "<wait10s>${var.guest_password}<enter>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><wait1s><spacebar>",
    "<wait10s><leftAltOn>q<leftAltOff>",
  ]
}

build {
  sources = ["source.tart-cli.sequoia"]

  provisioner "shell" {
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
    ]
    script = "scripts/guest/configure-vanilla.sh"
  }

  provisioner "shell" {
    script = "scripts/guest/install-command-line-tools.sh"
  }
}
