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

variable "guest_username" {
  type = string
}

variable "guest_password" {
  type      = string
  sensitive = true
}

source "tart-cli" "base" {
  vm_name            = var.vm_name
  headless           = true
  recovery_partition = "keep"
  ssh_username       = var.guest_username
  ssh_password       = var.guest_password
  ssh_timeout        = "10m"
}

build {
  sources = ["source.tart-cli.base"]

  provisioner "file" {
    source      = "scripts/guest/user-tcc-database.sh"
    destination = "/tmp/macos-image-user-tcc-database.sh"
  }

  provisioner "file" {
    source      = "data/Brewfile.base"
    destination = "/tmp/Brewfile.base"
  }

  provisioner "file" {
    source      = "data/github_known_hosts"
    destination = "/tmp/github_known_hosts"
  }

  provisioner "file" {
    source      = "data/limit.maxfiles.plist"
    destination = "/tmp/limit.maxfiles.plist"
  }

  provisioner "file" {
    source      = "data/tart-guest-agent.plist"
    destination = "/tmp/tart-guest-agent.plist"
  }

  provisioner "file" {
    source      = "data/tart-guest-daemon.plist"
    destination = "/tmp/tart-guest-daemon.plist"
  }

  provisioner "shell" {
    environment_vars = [
      "EXPECTED_VERSION=${var.expected_version}",
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
    ]
    scripts = [
      "scripts/guest/configure-system.sh",
      "scripts/guest/install-base-tools.sh",
      "scripts/guest/install-actions-runner.sh",
      "scripts/guest/configure-automation.sh",
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "GUEST_PASSWORD=${var.guest_password}",
      "GUEST_USERNAME=${var.guest_username}",
    ]
    script = "scripts/guest/enable-automation-mode.expect"
  }

  provisioner "shell" {
    environment_vars = ["GUEST_USERNAME=${var.guest_username}"]
    scripts = [
      "scripts/guest/cleanup-build.sh",
      "scripts/guest/verify-base.sh",
    ]
  }
}
