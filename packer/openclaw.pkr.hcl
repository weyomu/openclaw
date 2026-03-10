packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}
variable "azure_client_id" {}
variable "azure_client_secret" {}
variable "azure_tenant_id" {}
variable "azure_subscription_id" {}

locals {
  image_name = "openclaw-ubuntu24-${formatdate("YYYYMMDDhhmmss", timestamp())}"
}

source "azure-arm" "ubuntu24" {
  client_id                         = var.azure_client_id
  client_secret                     = var.azure_client_secret
  tenant_id                         = var.azure_tenant_id
  subscription_id                   = var.azure_subscription_id

  build_resource_group_name         = "rg-image-builders"
  managed_image_resource_group_name = "rg-image-builders"
  managed_image_name                = local.image_name

  os_type                           = "Linux"
  image_publisher                   = "Canonical"
  image_offer                       = "ubuntu-24_04-lts"
  image_sku                         = "server"

  vm_size                           = "Standard_DC2s_v3"
  ssh_username                      = "packeruser"

}

build {
  name = "openclaw-custom-image"
  sources = ["source.azure-arm.ubuntu24"]

  # Upload a tarball so scp does not have to handle a "." source path.
  provisioner "file" {
    source      = "openclaw-src.tgz"
    destination = "/tmp/openclaw-src.tgz"
  }

  provisioner "shell" {
    inline = [
      "rm -rf /tmp/openclaw",
      "mkdir -p /tmp/openclaw",
      "tar -xzf /tmp/openclaw-src.tgz -C /tmp/openclaw",
      "sudo chmod +x /tmp/openclaw/install.sh",
      "sudo /tmp/openclaw/install.sh",

      # 关键：清理 VM（必须！）
      "echo 'Deprovisioning VM for generalization...'",
      "sudo waagent -force -deprovision+user",
      "exit 0"
    ]
  }
}
