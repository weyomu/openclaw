#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[openclaw-gateway] $1"; }
log_step() { log "--- $1 ---"; }

# Section 2: apt-get update + base packages
log_step "Updating system and installing base packages"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git unzip build-essential ca-certificates gnupg lsb-release software-properties-common systemd jq

# Section 3: Language runtime (Node.js via NodeSource)
log_step "Installing Node.js (NodeSource)"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g pnpm@latest

# Section 4: Clone repo + build
log_step "Cloning repository and building"
rm -rf /opt/openclaw-gateway
git clone --depth 1 https://github.com/openclaw/openclaw /opt/openclaw-gateway
cd /opt/openclaw-gateway
pnpm install
pnpm build

# Section 5: Create system user
log_step "Creating system user"
useradd --system --home /opt/openclaw-gateway --shell /usr/sbin/nologin openclaw-gateway || true

# Section 6: Create directories
log_step "Preparing directories"
mkdir -p /var/lib/openclaw-gateway
mkdir -p /var/log/openclaw-gateway
chown -R openclaw-gateway:openclaw-gateway /var/lib/openclaw-gateway /var/log/openclaw-gateway /opt/openclaw-gateway

# Section 7: systemd service
log_step "Creating systemd service"
cat >/etc/systemd/system/openclaw-gateway.service <<'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=openclaw-gateway
WorkingDirectory=/opt/openclaw-gateway
ExecStart=/usr/local/bin/pnpm start
Restart=always
Environment=NODE_ENV=production
StandardOutput=append:/var/log/openclaw-gateway/output.log
StandardError=append:/var/log/openclaw-gateway/error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw-gateway

# Section 8: walinuxagent
log_step "Installing Azure Linux Agent"
apt-get install -y walinuxagent
systemctl enable walinuxagent

# Section 9: UFW rules
log_step "Configuring UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable

# Section 10: Limits + sysctl
log_step "Configuring system limits and sysctl"
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf

cat >/etc/sysctl.d/99-openclaw-gateway.conf <<'EOF'
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.core.netdev_max_backlog = 4096
EOF

sysctl --system

# Section 11: Complete
log_step "Installation complete. Service will start automatically on deployed VM."