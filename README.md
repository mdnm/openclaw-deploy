# OpenClaw Secure Deployment — Ubuntu 22.04

## Quick Deploy

```bash
# From your local machine:
scp -r openclaw-deploy/ user@server:~/openclaw-deploy/

# On the server:
ssh user@server
cd ~/openclaw-deploy
cp .env.example .env
nano .env              # Fill in OPENCLAW_GATEWAY_PASSWORD and TELEGRAM_BOT_TOKEN
sudo bash install_and_harden.sh
```

## Required Environment Variables

| Variable | Description | How to generate |
|----------|-------------|-----------------|
| `OPENCLAW_GATEWAY_PASSWORD` | Password for gateway authentication | `openssl rand -base64 32` |
| `TELEGRAM_BOT_TOKEN` | Bot API token from Telegram | Message [@BotFather](https://t.me/BotFather) on Telegram |

## Post-Install Steps

1. **Authenticate Tailscale** (interactive — cannot be scripted):
   ```bash
   sudo tailscale up
   ```

2. **Enable Tailscale Serve** — re-run the installer after authenticating:
   ```bash
   sudo bash ~/openclaw-deploy/install_and_harden.sh
   ```
   Or manually:
   ```bash
   sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
   ```

3. **OAuth setup** — run `openclaw auth` via SSH tunnel:
   ```bash
   # From your local machine (forward port 18789):
   ssh -L 18789:127.0.0.1:18789 user@server
   # Then open http://localhost:18789 in your browser to complete OAuth
   ```

## Architecture

```
Telegram Bot API
       │
       ▼
┌──────────────────┐
│  OpenClaw Gateway │  ← bound to 127.0.0.1:18789 (loopback only)
│  (Docker, non-root)│
└──────┬───────────┘
       │
       ▼
Tailscale Serve (HTTPS :443)
       │
       ▼
  Tailnet devices only (not public internet)
```

**Defense in depth:**
- **Network:** loopback bind + UFW default-deny + Tailscale Serve (not Funnel)
- **Auth:** gateway password + Tailscale identity + Telegram DM pairing
- **Process:** non-root `openclaw` user + Docker non-root + agent sandbox (`non-main`)
- **Monitoring:** Fail2ban (SSH) + `openclaw doctor` + `openclaw security audit`
- **Patching:** unattended-upgrades (security updates daily)

## Maintenance

### Upgrade OpenClaw

```bash
cd /home/openclaw
sudo -u openclaw docker compose pull
sudo -u openclaw docker compose up -d
```

### View Logs

```bash
# Docker logs
sudo -u openclaw docker compose -f /home/openclaw/docker-compose.yml logs -f gateway

# Application logs
tail -f /var/log/openclaw/*.log
```

### Health Check

```bash
sudo -u openclaw openclaw doctor --non-interactive
sudo -u openclaw openclaw security audit --deep
```

### Restart Gateway

```bash
cd /home/openclaw
sudo -u openclaw docker compose restart gateway
```

## Uninstall / Rollback

Each step is independent. Run only what you need. **Destructive steps are marked.**

1. **Stop and remove containers:**
   ```bash
   cd /home/openclaw && sudo -u openclaw docker compose down
   ```

2. **Remove Tailscale Serve:**
   ```bash
   sudo tailscale serve --remove --https=443
   ```

3. **⚠️ Delete OpenClaw data** (irreversible):
   ```bash
   sudo rm -rf /home/openclaw/.openclaw
   sudo rm -rf /var/log/openclaw
   ```

4. **Remove openclaw user:**
   ```bash
   sudo userdel -r openclaw
   ```

5. **Remove UFW rules:**
   ```bash
   sudo ufw delete deny 18789/tcp
   sudo ufw delete allow in on tailscale0
   ```

6. **Remove Fail2ban config:**
   ```bash
   sudo rm /etc/fail2ban/jail.local
   sudo systemctl restart fail2ban
   ```

7. **Remove logrotate config:**
   ```bash
   sudo rm /etc/logrotate.d/openclaw
   ```

8. **⚠️ Uninstall Tailscale** (removes from tailnet):
   ```bash
   sudo tailscale down
   sudo apt-get purge -y tailscale
   ```

9. **⚠️ Uninstall Docker** (affects all containers):
   ```bash
   sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
     docker-buildx-plugin docker-compose-plugin
   ```

10. **Remove deployment files:**
    ```bash
    rm -rf ~/openclaw-deploy
    ```
