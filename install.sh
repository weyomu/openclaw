#!/bin/bash
set -e

echo "=== Installing OpenClaw from source ==="

# 1. 安装 Node.js 22.x (官方推荐)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. 安装 pnpm
npm install -g pnpm

# 3. 确保 /opt/openclaw 目录存在
sudo mkdir -p /opt/openclaw

# 4. 复制当前目录所有文件到 /opt/openclaw（Packer 会把源码传进来）
# 注意：Packer 会把整个 repo 传到 /tmp/openclaw，我们假设它在 /tmp
if [ -d "/tmp/openclaw" ]; then
  sudo cp -r /tmp/openclaw/* /opt/openclaw/
else
  echo "ERROR: Source not found in /tmp/openclaw"
  exit 1
fi

# 5. 进入目录并安装依赖、构建
cd /opt/openclaw
sudo chown -R $(whoami):$(whoami) .
pnpm install
pnpm build

# 6. 创建 systemd 服务文件
cat << 'EOF' | sudo tee /etc/systemd/system/openclaw.service
[Unit]
Description=OpenClaw AI Assistant Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openclaw
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# 7. 重载 systemd 并启用服务（不启动！只 enable）
sudo systemctl daemon-reload
sudo systemctl enable openclaw

echo "=== OpenClaw installed and enabled ==="
echo "Service will start on boot."