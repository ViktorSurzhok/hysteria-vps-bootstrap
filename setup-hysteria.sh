#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GRN}[INFO]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }

DOMAIN=""
EMAIL=""
PASSWORD=""
PORT="8443"
WEBROOT=""
SITE_TITLE="Инфраструктурный узел активен."

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root: sudo bash $0 ..."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"; shift 2 ;;
      --email)
        EMAIL="${2:-}"; shift 2 ;;
      --password)
        PASSWORD="${2:-}"; shift 2 ;;
      --port)
        PORT="${2:-8443}"; shift 2 ;;
      --webroot)
        WEBROOT="${2:-}"; shift 2 ;;
      --site-title)
        SITE_TITLE="${2:-Инфраструктурный узел активен.}"; shift 2 ;;
      -h|--help)
        sed -n '1,120p' "$0"
        exit 0 ;;
      *)
        err "Unknown argument: $1"
        exit 1 ;;
    esac
  done

  [[ -z "$DOMAIN" ]] && { err "--domain is required"; exit 1; }
  [[ -z "$EMAIL" ]] && { err "--email is required"; exit 1; }
  [[ -z "$PASSWORD" ]] && { err "--password is required"; exit 1; }

  if [[ -z "$WEBROOT" ]]; then
    WEBROOT="/var/www/${DOMAIN}"
  fi

  if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    err "--port must be numeric"
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    err "Only apt-based systems are supported in this script."
    exit 1
  fi
}

install_base_packages() {
  log "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl \
    wget \
    ca-certificates \
    nginx \
    certbot \
    python3-certbot-nginx \
    jq \
    dnsutils \
    ufw
}

check_dns() {
  log "Checking DNS for ${DOMAIN}..."
  local resolved_ip
  resolved_ip="$(dig +short A "$DOMAIN" | tail -n1 || true)"
  if [[ -z "$resolved_ip" ]]; then
    warn "DNS A record for ${DOMAIN} is not resolving yet."
    warn "Make sure domain points to this VPS before continuing."
  else
    log "Domain ${DOMAIN} resolves to: ${resolved_ip}"
  fi
}

get_public_ip() {
  curl -4 -fsSL https://api.ipify.org || true
}

configure_firewall() {
  log "Configuring firewall..."
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

write_http_site() {
  log "Creating HTTP site for ACME challenge..."
  mkdir -p "$WEBROOT"

  local public_ip generated_at
  public_ip="$(get_public_ip)"
  generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  cat > "${WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <title>${DOMAIN}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg-1: #07122f;
      --bg-2: #0b1d4e;
      --card: rgba(19, 31, 66, 0.9);
      --card-2: rgba(255, 255, 255, 0.04);
      --line: rgba(255, 255, 255, 0.08);
      --text: #ffffff;
      --muted: #b8c4da;
      --success: #22c55e;
      --shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
      --radius: 28px;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Arial, sans-serif;
      background:
        radial-gradient(circle at top left, rgba(96, 165, 250, 0.16), transparent 28%),
        radial-gradient(circle at top right, rgba(125, 211, 252, 0.12), transparent 24%),
        linear-gradient(180deg, var(--bg-2), var(--bg-1));
      display: grid;
      place-items: center;
      padding: 28px;
    }

    .panel {
      width: min(100%, 760px);
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
      backdrop-filter: blur(10px);
      overflow: hidden;
    }

    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 18px 22px;
      border-bottom: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.02);
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
    }

    .brand-dot {
      width: 12px;
      height: 12px;
      border-radius: 999px;
      background: linear-gradient(135deg, #22c55e, #86efac);
      box-shadow: 0 0 18px rgba(34, 197, 94, 0.7);
      flex: 0 0 auto;
    }

    .brand-title {
      font-size: 14px;
      font-weight: 700;
      letter-spacing: 0.06em;
      color: var(--muted);
      text-transform: uppercase;
      white-space: nowrap;
    }

    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(34, 197, 94, 0.12);
      border: 1px solid rgba(34, 197, 94, 0.22);
      font-size: 13px;
      font-weight: 700;
      color: #dcfce7;
      white-space: nowrap;
    }

    .status::before {
      content: "";
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: #22c55e;
      box-shadow: 0 0 12px rgba(34, 197, 94, 0.8);
    }

    .content {
      padding: 34px 28px 28px;
    }

    .hero {
      display: grid;
      gap: 12px;
      margin-bottom: 28px;
    }

    .domain {
      margin: 0;
      font-size: clamp(28px, 5vw, 48px);
      line-height: 1.02;
      font-weight: 800;
      letter-spacing: -0.03em;
      word-break: break-word;
    }

    .subtitle {
      margin: 0;
      color: var(--muted);
      font-size: 18px;
      line-height: 1.5;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
      margin-bottom: 22px;
    }

    .item {
      background: var(--card-2);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 16px 16px 14px;
    }

    .label {
      font-size: 12px;
      line-height: 1.2;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 10px;
    }

    .value {
      font-size: 19px;
      line-height: 1.35;
      font-weight: 700;
      color: var(--text);
      word-break: break-word;
    }

    .footer {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      flex-wrap: wrap;
      border-top: 1px solid var(--line);
      padding-top: 18px;
      color: var(--muted);
      font-size: 14px;
    }

    .footer strong {
      color: var(--text);
      font-weight: 700;
    }

    @media (max-width: 680px) {
      .grid {
        grid-template-columns: 1fr;
      }

      .topbar {
        flex-direction: column;
        align-items: flex-start;
        gap: 12px;
      }
    }
  </style>
</head>
<body>
  <section class="panel">
    <div class="topbar">
      <div class="brand">
        <div class="brand-dot"></div>
        <div class="brand-title">Infrastructure Node</div>
      </div>
      <div class="status">ONLINE</div>
    </div>

    <div class="content">
      <div class="hero">
        <h1 class="domain">${DOMAIN}</h1>
        <p class="subtitle">${SITE_TITLE}</p>
      </div>

      <div class="grid">
        <div class="item">
          <div class="label">Server IP</div>
          <div class="value">${public_ip:-unknown}</div>
        </div>
        <div class="item">
          <div class="label">Hysteria Port</div>
          <div class="value">${PORT}/udp</div>
        </div>
        <div class="item">
          <div class="label">TLS SNI</div>
          <div class="value">${DOMAIN}</div>
        </div>
        <div class="item">
          <div class="label">Environment</div>
          <div class="value">Nginx + Hysteria 2</div>
        </div>
      </div>

      <div class="footer">
        <div>Generated: <strong>${generated_at}</strong></div>
        <div>Status page: <strong>active</strong></div>
      </div>
    </div>
  </section>
</body>
</html>
EOF

  cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

issue_certificate() {
  log "Issuing Let's Encrypt certificate..."
  certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL" \
    --redirect
}

write_https_site() {
  log "Refreshing HTTPS nginx config..."
  cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  nginx -t
  systemctl restart nginx
}

install_hysteria() {
  log "Installing Hysteria2..."
  bash <(curl -fsSL https://get.hy2.sh/)
}

write_hysteria_config() {
  log "Writing Hysteria config..."
  mkdir -p /etc/hysteria

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem

auth:
  type: password
  password: ${PASSWORD}

resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53

masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}
    rewriteHost: true
EOF
}

ensure_hysteria_restart_policy() {
  log "Ensuring Hysteria auto-restart policy..."
  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=5
EOF

  systemctl daemon-reload
}

start_hysteria() {
  log "Starting Hysteria..."
  systemctl enable hysteria-server
  systemctl restart hysteria-server
}

verify_services() {
  log "Verifying nginx..."
  systemctl is-active --quiet nginx || { err "nginx is not active"; exit 1; }

  log "Verifying hysteria..."
  systemctl is-active --quiet hysteria-server || { err "hysteria-server is not active"; exit 1; }

  log "Checking listening ports..."
  ss -tulnp | grep -E ":80|:443|:${PORT}" || true
}

print_summary() {
  local public_ip
  public_ip="$(get_public_ip)"

  echo
  echo -e "${BLU}==================== RESULT ====================${NC}"
  echo "Domain:              ${DOMAIN}"
  echo "Public IP:           ${public_ip:-unknown}"
  echo "Website:             https://${DOMAIN}"
  echo "Hysteria server:     ${DOMAIN}:${PORT}"
  echo "Password:            ${PASSWORD}"
  echo "TLS SNI:             ${DOMAIN}"
  echo "Cert path:           /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  echo "Key path:            /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  echo
  echo "Suggested Surge node:"
  echo "  Protocol:          Hysteria 2"
  echo "  Server Address:    ${public_ip:-${DOMAIN}}"
  echo "  Port:              ${PORT}"
  echo "  Password:          ${PASSWORD}"
  echo "  Custom TLS SNI:    ${DOMAIN}"
  echo
  echo "Useful checks:"
  echo "  systemctl status hysteria-server --no-pager -l"
  echo "  journalctl -u hysteria-server -f --no-pager"
  echo "  systemctl status nginx --no-pager -l"
  echo "  curl -I https://${DOMAIN}"
  echo -e "${BLU}================================================${NC}"
}

main() {
  require_root
  parse_args "$@"
  detect_pkg_manager >/dev/null
  install_base_packages
  check_dns
  configure_firewall
  write_http_site
  issue_certificate
  write_https_site
  install_hysteria
  write_hysteria_config
  ensure_hysteria_restart_policy
  start_hysteria
  verify_services
  print_summary
}

main "$@"
