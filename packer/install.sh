#!/usr/bin/env bash
# =============================================================================
# install.sh
# 在 Ubuntu 24.04 LTS 上安装 OpenClaw，并配置为 systemd 服务
#
# 此脚本由 Packer 在构建 VM 镜像时调用，运行在临时 Azure VM 内。
# 脚本结束后，Packer 会 deprovision 并生成通用化镜像。
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色输出工具
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${GREEN}==>${NC} $*\n"; }

# ---------------------------------------------------------------------------
# 1. 系统基础更新
# ---------------------------------------------------------------------------
log_step "Step 1: Updating system packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

# 安装基础依赖
apt-get install -y \
  curl \
  wget \
  git \
  unzip \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  systemd \
  jq

log_info "System packages updated"

# ---------------------------------------------------------------------------
# 2. 安装 Node.js 22（OpenClaw 要求 Node >= 22）
# ---------------------------------------------------------------------------
log_step "Step 2: Installing Node.js 22"

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

NODE_VERSION=$(node --version)
NPM_VERSION=$(npm --version)
log_info "Node.js installed: ${NODE_VERSION}, npm: ${NPM_VERSION}"

# ---------------------------------------------------------------------------
# 3. 安装 pnpm（OpenClaw 推荐使用 pnpm）
# ---------------------------------------------------------------------------
log_step "Step 3: Installing pnpm"

npm install -g pnpm@latest
PNPM_VERSION=$(pnpm --version)
log_info "pnpm installed: ${PNPM_VERSION}"

# ---------------------------------------------------------------------------
# 4. 安装 OpenClaw
# ---------------------------------------------------------------------------
log_step "Step 4: Installing OpenClaw"

# 方式 A：从 npm 安装稳定版（推荐生产环境）
npm install -g openclaw@latest

OPENCLAW_VERSION=$(openclaw --version 2>/dev/null || echo "installed")
log_info "OpenClaw installed: ${OPENCLAW_VERSION}"

# 方式 B（可选）：从源码安装
# 如需从源码构建，注释掉方式 A，取消注释以下代码：
#
# OPENCLAW_REPO="https://github.com/weyomu/openclaw.git"
# OPENCLAW_DIR="/opt/openclaw-src"
#
# git clone --depth 1 "${OPENCLAW_REPO}" "${OPENCLAW_DIR}"
# cd "${OPENCLAW_DIR}"
# pnpm install --frozen-lockfile
# pnpm ui:build
# pnpm build
# npm install -g .
# cd /
# rm -rf "${OPENCLAW_DIR}"

# ---------------------------------------------------------------------------
# 5. 创建运行用户（非 root）
# ---------------------------------------------------------------------------
log_step "Step 5: Creating openclaw system user"

if ! id "openclaw" &>/dev/null; then
  useradd \
    --system \
    --create-home \
    --home-dir /var/lib/openclaw \
    --shell /bin/bash \
    --comment "OpenClaw Service" \
    openclaw
  log_info "User 'openclaw' created"
else
  log_warn "User 'openclaw' already exists, skipping"
fi

# ---------------------------------------------------------------------------
# 6. 创建配置目录结构
# ---------------------------------------------------------------------------
log_step "Step 6: Creating directory structure"

OPENCLAW_HOME="/var/lib/openclaw"
OPENCLAW_CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
OPENCLAW_LOG_DIR="/var/log/openclaw"

mkdir -p \
  "${OPENCLAW_CONFIG_DIR}" \
  "${OPENCLAW_CONFIG_DIR}/workspace" \
  "${OPENCLAW_LOG_DIR}"

# 创建最小化启动配置（用户部署后需覆盖此文件填入真实 API Key）
cat > "${OPENCLAW_CONFIG_DIR}/openclaw.json" << 'EOF'
{
  "agent": {
    "model": "openai/gpt-4o"
  },
  "gateway": {
    "port": 18789,
    "bind": "loopback"
  }
}
EOF

chown -R openclaw:openclaw "${OPENCLAW_HOME}" "${OPENCLAW_LOG_DIR}"
chmod 750 "${OPENCLAW_CONFIG_DIR}"
chmod 640 "${OPENCLAW_CONFIG_DIR}/openclaw.json"

log_info "Directory structure created at ${OPENCLAW_HOME}"

# ---------------------------------------------------------------------------
# 7. 创建 systemd 服务单元
# ---------------------------------------------------------------------------
log_step "Step 7: Creating systemd service"

OPENCLAW_BIN=$(which openclaw)

cat > /etc/systemd/system/openclaw.service << EOF
[Unit]
Description=OpenClaw Personal AI Assistant Gateway
Documentation=https://openclaw.ai/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/var/lib/openclaw
Environment="HOME=/var/lib/openclaw"
Environment="NODE_ENV=production"

# 启动命令：以 Gateway 模式运行
ExecStart=${OPENCLAW_BIN} gateway --port 18789
ExecReload=/bin/kill -HUP \$MAINPID

# 重启策略
Restart=on-failure
RestartSec=10s
StartLimitIntervalSec=60s
StartLimitBurst=3

# 日志
StandardOutput=append:/var/log/openclaw/gateway.log
StandardError=append:/var/log/openclaw/gateway.error.log

# 安全加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/openclaw /var/log/openclaw

[Install]
WantedBy=multi-user.target
EOF

# 启用服务（开机自启），但在镜像构建阶段不实际启动
systemctl daemon-reload
systemctl enable openclaw.service

log_info "systemd service 'openclaw' enabled (will start on first boot)"

# ---------------------------------------------------------------------------
# 8. 安装 Azure Linux Agent（walinuxagent）
# ---------------------------------------------------------------------------
log_step "Step 8: Ensuring Azure Linux Agent is installed"

# Ubuntu 24.04 通常预装，确保为最新版
apt-get install -y walinuxagent

systemctl enable walinuxagent

log_info "Azure Linux Agent (walinuxagent) installed and enabled"

# ---------------------------------------------------------------------------
# 9. 配置防火墙（仅开放 SSH 和 OpenClaw Gateway 端口）
# ---------------------------------------------------------------------------
log_step "Step 9: Configuring UFW firewall"

apt-get install -y ufw

# 默认拒绝入站
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# 允许 SSH（必须保留，否则无法远程管理）
ufw allow 22/tcp comment 'SSH'

# 允许 OpenClaw Gateway WebSocket（仅内网访问，外部通过 Tailscale 或 SSH 隧道）
# 如需公网访问，请在 Azure NSG 中控制，不在此开放
# ufw allow 18789/tcp comment 'OpenClaw Gateway'

ufw --force enable

log_info "Firewall configured"

# ---------------------------------------------------------------------------
# 10. 系统优化（针对 AI 工作负载）
# ---------------------------------------------------------------------------
log_step "Step 10: Applying system optimizations"

# 增大文件描述符限制
cat >> /etc/security/limits.conf << 'EOF'
openclaw soft nofile 65536
openclaw hard nofile 65536
EOF

# 调整内核参数
cat >> /etc/sysctl.d/99-openclaw.conf << 'EOF'
# 增大 TCP 缓冲区（WebSocket 长连接优化）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# 优化连接队列
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF

sysctl -p /etc/sysctl.d/99-openclaw.conf 2>/dev/null || true

log_info "System optimizations applied"

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
log_step "Installation complete"

echo ""
log_info "OpenClaw has been installed successfully."
log_info ""
log_info "After deploying a VM from this image:"
log_info "  1. Edit /var/lib/openclaw/.openclaw/openclaw.json with your API keys"
log_info "  2. Run: sudo systemctl start openclaw"
log_info "  3. Check status: sudo systemctl status openclaw"
log_info "  4. View logs: sudo journalctl -u openclaw -f"
echo ""
