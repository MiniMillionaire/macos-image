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

variable "installer_archive" {
  type = string
}

variable "installer_app" {
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

source "tart-cli" "upgrade" {
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
  sources = ["source.tart-cli.upgrade"]

  provisioner "shell" {
    timeout = "5m"
    inline = [
      "test \"$(sw_vers -productVersion)\" = '${var.source_version}'",
      "test \"$(sw_vers -buildVersion)\" = '${var.source_build}'",
    ]
  }

  provisioner "file" {
    timeout     = "30m"
    source      = var.installer_archive
    destination = "/tmp/macos-image-InstallAssistant.pkg"
  }

  provisioner "shell" {
    timeout = "30m"
    environment_vars = [
      "EXPECTED_VERSION=${var.expected_version}",
      "EXPECTED_BUILD=${var.expected_build}",
      "INSTALLER_APP=${var.installer_app}",
      "TARGET_DISK_SIZE_GB=${var.disk_size_gb}",
    ]
    scripts = [
      "scripts/guest/verify-resize.sh",
      "scripts/guest/prepare-macos-upgrade.sh",
    ]
  }

  provisioner "shell" {
    timeout           = "90m"
    expect_disconnect = true
    skip_clean        = true
    remote_path       = "/var/tmp/macos-image-start-upgrade.sh"
    environment_vars = [
      "GUEST_USERNAME=${var.guest_username}",
      "GUEST_PASSWORD=${var.guest_password}",
      "INSTALLER_APP=${var.installer_app}",
    ]
    inline = [
      "printf '%s\\n' \"$GUEST_PASSWORD\" | sudo -n \"$INSTALLER_APP/Contents/Resources/startosinstall\" --agreetolicense --forcequitapps --rebootdelay 5 --user \"$GUEST_USERNAME\" --stdinpass",
    ]
  }

  provisioner "shell" {
    pause_before        = "2m"
    start_retry_timeout = "90m"
    timeout             = "95m"
    environment_vars = [
      "EXPECTED_VERSION=${var.expected_version}",
      "EXPECTED_BUILD=${var.expected_build}",
      "INSTALLER_APP=${var.installer_app}",
    ]
    script = "scripts/guest/finish-macos-upgrade.sh"
  }
}
