# =============================================================================
# openclaw.pkr.hcl
# Build flow:
#   Step 1 (this file): Packer builds a managed image in rg-image-builders
#   Step 2 (workflow):  az sig image-version create publishes it to SIG
#
# Required env vars: ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
# =============================================================================

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "subscription_id" {
  type    = string
  default = env("ARM_SUBSCRIPTION_ID")
}

variable "client_id" {
  type    = string
  default = env("ARM_CLIENT_ID")
}

variable "client_secret" {
  type      = string
  sensitive = true
  default   = env("ARM_CLIENT_SECRET")
}

variable "tenant_id" {
  type    = string
  default = env("ARM_TENANT_ID")
}

variable "image_version" {
  type        = string
  description = "SIG image version, format: major.minor.patch"
  default     = "1.0.0"
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  # Managed image (intermediate) - stored in rg-image-builders
  managed_image_rg   = "rg-image-builders"
  managed_image_name = "openclaw-${var.image_version}"

  # Packer build VM uses this existing resource group
  build_resource_group = "rg-packer-build"

  location = "East US"

  tags = {
    project  = "openclaw"
    built_by = "packer"
    version  = var.image_version
  }
}

# ---------------------------------------------------------------------------
# Source: build managed image first (same approach that worked before)
# ---------------------------------------------------------------------------

source "azure-arm" "openclaw_ubuntu" {
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id

  # Use existing resource group for the build VM
  build_resource_group_name = local.build_resource_group

  # Output: managed image (intermediate step before SIG)
  managed_image_resource_group_name = local.managed_image_rg
  managed_image_name                = local.managed_image_name

  # Base image: Ubuntu 24.04 LTS
  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  # VM size that works in eastus
  vm_size      = "Standard_DC2s_v3"
  ssh_username = "packeruser"

  os_disk_size_gb = 64

  azure_tags = local.tags
}

# ---------------------------------------------------------------------------
# Build: install OpenClaw, then deprovision
# ---------------------------------------------------------------------------

build {
  name    = "openclaw-vm-image"
  sources = ["source.azure-arm.openclaw_ubuntu"]

  # Upload install script
  provisioner "file" {
    source      = "${path.root}/install.sh"
    destination = "/tmp/install.sh"
  }

  # Run install script
  provisioner "shell" {
    inline  = ["chmod +x /tmp/install.sh", "sudo /tmp/install.sh"]
    timeout = "30m"
  }

  # Verify OpenClaw is installed correctly
  # Note: service is enabled but not started during image build (starts on first boot)
  provisioner "shell" {
    inline = [
      "systemctl is-enabled openclaw || (echo 'ERROR: openclaw service not enabled' && exit 1)",
      "openclaw --version || true",
      "sudo test -f /var/lib/openclaw/.openclaw/openclaw.json || (echo 'ERROR: config file missing' && exit 1)",
      "echo 'OpenClaw installation verified successfully'",
    ]
  }

  # Deprovision (generalize) - must be last
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      "rm -f /tmp/install.sh",
      "/usr/sbin/waagent -force -deprovision+user",
      "export HISTSIZE=0",
      "sync",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
  }
}
