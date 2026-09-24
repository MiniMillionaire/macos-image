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

variable "source_version" {
  type = string
}

variable "source_build" {
  type = string
}

variable "expected_version" {
  type = string
}

variable "expected_build" {
  type = string
}

variable "update_title" {
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

source "tart-cli" "update" {
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
  sources = ["source.tart-cli.update"]

  provisioner "shell" {
    timeout = "15m"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
      "SOURCE_BUILD=${var.source_build}",
      "SOURCE_VERSION=${var.source_version}",
      "TARGET_DISK_SIZE_GB=${var.disk_size_gb}",
      "UPDATE_TITLE=${var.update_title}",
    ]
    scripts = [
      "scripts/guest/verify-resize.sh",
      "scripts/guest/prepare-software-update.sh",
    ]
  }

  provisioner "shell" {
    timeout           = "75m"
    expect_disconnect = true
    skip_clean        = true
    remote_path       = "/var/tmp/macos-image-software-update.sh"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
      "UPDATE_TITLE=${var.update_title}",
    ]
    inline = [
      "update_label=\"macOS $UPDATE_TITLE $EXPECTED_VERSION-$EXPECTED_BUILD\"; printf '%s\\n' \"$GUEST_PASSWORD\" | sudo -n softwareupdate --install \"$update_label\" --restart --user \"$GUEST_USERNAME\" --stdinpass --agree-to-license",
    ]
  }

  provisioner "shell" {
    pause_before        = "1m"
    start_retry_timeout = "25m"
    timeout             = "30m"
    environment_vars = [
      "EXPECTED_BUILD=${var.expected_build}",
      "EXPECTED_VERSION=${var.expected_version}",
    ]
    script = "scripts/guest/finish-software-update.sh"
  }
}
