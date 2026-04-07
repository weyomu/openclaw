# =============================================================================
# openclaw.pkr.hcl
# Packer 配置文件：在 Ubuntu 24.04 LTS 上安装 OpenClaw，并发布到 Azure SIG
#
# 使用方式：
#   packer init .
#   packer validate .
#   packer build -var "image_version=1.0.0" .
#
# 所需环境变量（从 GitHub Secrets 注入，或本地 export 设置）：
#   ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
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
# 变量定义
# ---------------------------------------------------------------------------

variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID"
  default     = env("ARM_SUBSCRIPTION_ID")
}

variable "client_id" {
  type        = string
  description = "Azure Service Principal Client ID"
  default     = env("ARM_CLIENT_ID")
}

variable "client_secret" {
  type        = string
  description = "Azure Service Principal Client Secret"
  sensitive   = true
  default     = env("ARM_CLIENT_SECRET")
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = env("ARM_TENANT_ID")
}

variable "image_version" {
  type        = string
  description = "SIG 中的镜像版本号，格式为 major.minor.patch，例如 1.0.0"
  default     = "1.0.0"
}

variable "location" {
  type        = string
  description = "Azure 区域"
  default     = "East US"
}

# ---------------------------------------------------------------------------
# 资源组 & SIG 配置（与你在 Azure 中已创建的资源对应）
# ---------------------------------------------------------------------------

locals {
  # 构建时使用的临时资源组（Packer 构建完成后会自动删除）
  build_resource_group = "rg-packer-build"

  # Shared Image Gallery 所在的资源组
  sig_resource_group = "rg-shared-images"

  # Shared Image Gallery 名称
  gallery_name = "MyGallery"

  # 镜像定义名称
  image_definition = "OpenClawImage"

  # 镜像标签，供 Azure 管理控制台筛选
  tags = {
    project     = "openclaw"
    environment = "production"
    built_by    = "packer"
  }
}

# ---------------------------------------------------------------------------
# Builder：使用 azure-arm 插件构建镜像
# ---------------------------------------------------------------------------

source "azure-arm" "openclaw_ubuntu" {
  # 认证
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id

  # 构建用的临时资源组（Packer 会自动创建和删除）
  build_resource_group_name = local.build_resource_group

  # 基础镜像：Ubuntu 24.04 LTS（Noble Numbat）
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  # 构建用的临时 VM 规格（构建完成后自动删除）
  vm_size = "Standard_D2s_v3"

  # 操作系统磁盘配置
  os_type         = "Linux"
  os_disk_size_gb = 64

  # 目标：发布到 Shared Image Gallery
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = local.sig_resource_group
    gallery_name         = local.gallery_name
    image_name           = local.image_definition
    image_version        = var.image_version
    replication_regions  = [var.location]
    storage_account_type = "Standard_LRS"
  }

  # 镜像已通用化（deprovision），可用于创建多台 VM
  generalize = true

  azure_tags = local.tags
}

# ---------------------------------------------------------------------------
# Provisioner：安装 OpenClaw
# ---------------------------------------------------------------------------

build {
  name    = "openclaw-vm-image"
  sources = ["source.azure-arm.openclaw_ubuntu"]

  # 1. 上传安装脚本到临时 VM
  provisioner "file" {
    source      = "${path.root}/install.sh"
    destination = "/tmp/install.sh"
  }

  # 2. 执行安装脚本
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/install.sh",
      "sudo /tmp/install.sh",
    ]
    # 设置超时，OpenClaw 构建可能需要较长时间
    timeout = "30m"
  }

  # 3. 验证安装结果（服务应处于运行状态）
  provisioner "shell" {
    inline = [
      "systemctl is-active openclaw || (echo 'ERROR: openclaw service is not running' && exit 1)",
      "openclaw --version || true",
      "echo 'OpenClaw installation verified successfully'",
    ]
  }

  # 4. 清理并通用化镜像（必须是最后一步）
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
      # 清理 apt 缓存
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      # 清理构建临时文件
      "rm -f /tmp/install.sh",
      # Azure Linux Agent deprovision（通用化），必须最后执行
      "/usr/sbin/waagent -force -deprovision+user",
      "export HISTSIZE=0",
      "sync",
    ]
  }

  # 5. 输出构建信息（可用于后续步骤读取版本）
  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
  }
}
