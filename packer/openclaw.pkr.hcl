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

  managed_image_resource_group_name = "rg-image-builders"
  managed_image_name                = local.image_name
  managed_image_location            = "East US"

  os_type                           = "Linux"
  image_publisher                   = "Canonical"
  image_offer                       = "0001-com-ubuntu-server-jammy"
  image_sku                         = "24_04-lts"

  vm_size                           = "Standard_D2s_v3"
  ssh_username                      = "packeruser"

  async_os_disk_cleanup             = true
  async_resourcegroup_cleanup       = true
}

build {
  name = "openclaw-custom-image"
  sources = ["source.azure-arm.ubuntu24"]

  # 上传整个 openclaw 目录到 /tmp/openclaw
  provisioner "file" {
    source      = "../."          # 当前 Git 仓库根目录
    destination = "/tmp/openclaw"
  }

  # 上传 install.sh 单独（确保权限）
  provisioner "file" {
    source      = "../install.sh"
    destination = "/tmp/install.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo chmod +x /tmp/install.sh",
      "sudo /tmp/install.sh",

      # 关键：清理 VM（必须！）
      "echo 'Deprovisioning VM for generalization...'",
      "sudo waagent -force -deprovision+user",
      "exit 0"
    ]
  }
}