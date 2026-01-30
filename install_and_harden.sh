#!/usr/bin/env bash
###############################################################################
# install_and_harden.sh — Idempotent provisioning for OpenClaw on Ubuntu 22.04
# Run as root:  sudo bash install_and_harden.sh
###############################################################################
set -euo pipefail

# ─── 1. Preamble ────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Must run as root." >&2
  exit 1
fi

if ! grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null; then
  echo "ERROR: This script targets Ubuntu 22.04 (Jammy)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  echo "ERROR: ${SCRIPT_DIR}/.env not found. Copy .env.example and fill in secrets." >&2
  exit 1
fi

# Source .env without echoing
set -a
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.env"
set +a

# Validate required secrets
: "${OPENCLAW_GATEWAY_PASSWORD:?ERROR: OPENCLAW_GATEWAY_PASSWORD is not set in .env}"
: "${TELEGRAM_BOT_TOKEN:?ERROR: TELEGRAM_BOT_TOKEN is not set in .env}"

echo "==> All required environment variables present."

# ─── 2. System updates + unattended-upgrades ────────────────────────────────
echo "==> Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

apt-get install -y -qq unattended-upgrades apt-transport-https ca-certificates \
  curl gnupg lsb-release jq gettext-base

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "==> Unattended-upgrades configured."

# ─── 3. Create openclaw user (UID 1000) ─────────────────────────────────────
if ! id -u openclaw &>/dev/null; then
  # If UID 1000 is taken by another user, warn and use next available
  if getent passwd 1000 &>/dev/null; then
    EXISTING_USER="$(getent passwd 1000 | cut -d: -f1)"
    echo "WARNING: UID 1000 is already taken by '${EXISTING_USER}'."
    echo "  The container runs as UID 1000. Either reassign that user's UID"
    echo "  or adjust docker-compose.yml. Creating openclaw with next free UID."
    useradd --system --create-home --shell /usr/sbin/nologin openclaw
  else
    useradd --system --create-home --shell /usr/sbin/nologin --uid 1000 openclaw
  fi
  echo "==> User 'openclaw' created."
else
  echo "==> User 'openclaw' already exists."
fi

# ─── 4. Node.js 22 ──────────────────────────────────────────────────────────
REQUIRED_NODE_MAJOR=22
CURRENT_NODE_MAJOR="$(node --version 2>/dev/null | grep -oP '(?<=v)\d+' || echo 0)"

if [[ "${CURRENT_NODE_MAJOR}" -lt "${REQUIRED_NODE_MAJOR}" ]]; then
  echo "==> Installing Node.js ${REQUIRED_NODE_MAJOR}..."
  curl -fsSL https://deb.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x | bash -
  apt-get install -y -qq nodejs
else
  echo "==> Node.js ${CURRENT_NODE_MAJOR} already installed."
fi

# ─── 5. Docker Engine ───────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
else
  echo "==> Docker already installed."
fi

systemctl enable --now docker

# Add openclaw to docker group
usermod -aG docker openclaw 2>/dev/null || true
echo "==> Docker ready; openclaw added to docker group."

# ─── 6. Tailscale ───────────────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
  echo "==> Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "==> Tailscale already installed."
fi

systemctl enable --now tailscaled
echo "==> Tailscale daemon enabled."
echo "NOTE: Run 'sudo tailscale up' interactively to authenticate this node."

# ─── 7. UFW ─────────────────────────────────────────────────────────────────
echo "==> Configuring UFW..."
apt-get install -y -qq ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow in on tailscale0
ufw deny 18789/tcp comment "Block external access to OpenClaw gateway"
ufw --force enable

echo "==> UFW configured and enabled."

# ─── 8. Fail2ban ────────────────────────────────────────────────────────────
echo "==> Configuring Fail2ban..."
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
echo "==> Fail2ban configured."

# ─── 9. OpenClaw dirs + config ──────────────────────────────────────────────
echo "==> Setting up OpenClaw directories and config..."
OPENCLAW_HOME="/home/openclaw"

mkdir -p "${OPENCLAW_HOME}/.openclaw/workspace"
mkdir -p "${OPENCLAW_HOME}/.openclaw/credentials"
mkdir -p "${OPENCLAW_HOME}/.openclaw/agents/main/sessions"
mkdir -p /var/log/openclaw

# Generate config from template if it does not already exist
CONFIG_FILE="${OPENCLAW_HOME}/.openclaw/openclaw.json"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  envsubst < "${SCRIPT_DIR}/openclaw.config.template.json" > "${CONFIG_FILE}"
  echo "==> Config written to ${CONFIG_FILE}."
else
  echo "==> Config already exists at ${CONFIG_FILE}; skipping to preserve edits."
fi

chown -R openclaw:openclaw "${OPENCLAW_HOME}/.openclaw"
chmod 700 "${OPENCLAW_HOME}/.openclaw"
chmod 700 "${OPENCLAW_HOME}/.openclaw/credentials"
chmod 600 "${CONFIG_FILE}" 2>/dev/null || true

chown -R openclaw:openclaw /var/log/openclaw
chmod 750 /var/log/openclaw

echo "==> Directories and permissions set."

# ─── 10. Deploy Docker Compose ──────────────────────────────────────────────
echo "==> Deploying Docker Compose..."
cp "${SCRIPT_DIR}/docker-compose.yml" "${OPENCLAW_HOME}/docker-compose.yml"
cp "${SCRIPT_DIR}/.env" "${OPENCLAW_HOME}/.env"
chown openclaw:openclaw "${OPENCLAW_HOME}/docker-compose.yml" "${OPENCLAW_HOME}/.env"
chmod 600 "${OPENCLAW_HOME}/.env"

cd "${OPENCLAW_HOME}"
sudo -u openclaw docker compose up -d
echo "==> Docker Compose services started."

# ─── 10a. Patch existing config (idempotent) ────────────────────────────────
# Since the config may already exist (skipped by envsubst guard above),
# apply critical fixes via openclaw config set commands.
echo "==> Applying config patches..."
sudo -u openclaw openclaw config set gateway.mode local 2>/dev/null || true
sudo -u openclaw openclaw config set channels.telegram.enabled true 2>/dev/null || true
sudo -u openclaw openclaw config set channels.telegram.groups.*.allowFrom pairing 2>/dev/null || true

# Remove password from config file — rely on OPENCLAW_GATEWAY_PASSWORD env var
if sudo -u openclaw jq -e '.gateway.auth.password' "${CONFIG_FILE}" &>/dev/null; then
  sudo -u openclaw jq 'del(.gateway.auth.password)' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" \
    && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
  chown openclaw:openclaw "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
  echo "==> Removed gateway password from config (using env var instead)."
fi

# ─── 10b. Build sandbox image ───────────────────────────────────────────────
if ! docker image inspect openclaw-sandbox:bookworm-slim &>/dev/null; then
  echo "==> Building sandbox base image..."
  # Use the container's bundled setup script
  sudo -u openclaw docker compose run --rm --entrypoint "" gateway \
    sh -c "[ -f /app/scripts/sandbox-setup.sh ] && /app/scripts/sandbox-setup.sh" 2>/dev/null || \
  echo "WARNING: Could not build sandbox image automatically."
  echo "  If sandbox is needed, run: openclaw sandbox setup"
else
  echo "==> Sandbox image already exists."
fi

# Restart gateway to pick up config changes
cd "${OPENCLAW_HOME}"
sudo -u openclaw docker compose restart gateway
echo "==> Gateway restarted with updated config."

# ─── 11. Tailscale Serve ────────────────────────────────────────────────────
if tailscale status &>/dev/null; then
  echo "==> Configuring Tailscale Serve..."
  tailscale serve --bg --https=443 http://127.0.0.1:18789
  echo "==> Tailscale Serve: HTTPS :443 → localhost:18789."
else
  echo "WARNING: Tailscale not authenticated. After running 'tailscale up',"
  echo "  re-run this script or manually run:"
  echo "  tailscale serve --bg --https=443 http://127.0.0.1:18789"
fi

# ─── 12. Log rotation ───────────────────────────────────────────────────────
echo "==> Configuring log rotation..."
cat > /etc/logrotate.d/openclaw <<'EOF'
/var/log/openclaw/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 openclaw openclaw
}
EOF

echo "==> Log rotation configured."

# ─── 13. openclaw doctor + security audit ────────────────────────────────────
echo "==> Running openclaw diagnostics..."
if ! command -v openclaw &>/dev/null; then
  npm install -g openclaw
fi

sudo -u openclaw openclaw doctor --non-interactive || true
sudo -u openclaw openclaw security audit --deep || true

echo ""
echo "=========================================="
echo "  OpenClaw Deployment Summary"
echo "=========================================="
echo ""
echo "--- UFW Status ---"
ufw status verbose
echo ""
echo "--- Fail2ban Status ---"
fail2ban-client status sshd 2>/dev/null || echo "(fail2ban not yet active)"
echo ""
echo "--- Docker Containers ---"
cd "${OPENCLAW_HOME}" && sudo -u openclaw docker compose ps
echo ""
echo "--- Tailscale Status ---"
tailscale status 2>/dev/null || echo "(Tailscale not authenticated)"
echo ""
echo "=========================================="
echo "  Deployment complete."
echo "  Next steps:"
echo "    1. Run 'sudo tailscale up' if not authenticated"
echo "    2. Re-run this script to enable Tailscale Serve"
echo "    3. Run 'openclaw auth' via SSH tunnel for OAuth"
echo "=========================================="
