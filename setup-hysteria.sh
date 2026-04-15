#!/usr/bin/env bash
# shellcheck shell=bash
#
# hysteria-vps-bootstrap — production-grade bootstrap for Hysteria 2 + Nginx + LE.
# See README.md for documentation. Run with --help for CLI usage.
#
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="hysteria-vps-bootstrap"
HYSTERIA_INSTALLER_URL="https://get.hy2.sh/"

# ---------- colors / logging ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; NC=""
fi

log()  { printf '%s[INFO]%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$NC" "$*"; }
err()  { printf '%s[ERR ]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

mask_secret() {
  local s="${1:-}"
  local n=${#s}
  if (( n == 0 )); then printf '(empty)'; return; fi
  if (( n <= 4 )); then printf '****'; return; fi
  printf '%s***%s' "${s:0:2}" "${s: -2}"
}

# HTML-escape for values interpolated into the status page template.
html_escape() {
  local s="${1:-}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

# ---------- defaults / state ----------
DOMAIN=""
EMAIL=""
PASSWORD=""
PASSWORD_FILE=""
PORT="8443"
WEBROOT=""
SITE_TITLE="Инфраструктурный узел активен."
CERT_MODE="copy"        # copy | acl
FORCE_RENEW="0"
ASSUME_YES="0"
BACKUP_DIR=""
HYSTERIA_CERT_PATH=""
HYSTERIA_KEY_PATH=""

# ---------- error trap ----------
on_error() {
  local ec=$? line=$1
  err "failed at line ${line} (exit ${ec})"
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    err "previous configs backed up at: ${BACKUP_DIR}"
    err "restore with: cp -a ${BACKUP_DIR}/nginx/. /etc/nginx/ && systemctl reload nginx"
  fi
  exit "$ec"
}
trap 'on_error $LINENO' ERR

# ---------- usage ----------
usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Bootstrap Hysteria 2 + Nginx + Let's Encrypt on a clean Debian/Ubuntu VPS.

Usage:
  sudo bash $0 --domain <fqdn> --email <addr> [--password <pw> | --password-file <path>] [options]

Required:
  --domain <fqdn>           FQDN with an A record pointing to this VPS.
  --email <addr>            Contact email for Let's Encrypt (use your own domain).
  --password <pw>           Hysteria 2 auth password.  (visible in ps; prefer --password-file)
  --password-file <path>    Read password from first line of file (chmod 600 recommended).

Options:
  --port <udp>              UDP port for Hysteria (default: 8443).
  --webroot <path>          Site root (default: /var/www/<domain>).
  --site-title <text>       Status page subtitle (HTML-escaped automatically).
  --cert-mode <copy|acl>    How Hysteria reads LE certs (default: copy).
                              copy: certbot deploy-hook copies certs to /etc/hysteria/certs.
                              acl : POSIX ACL on /etc/letsencrypt/archive (cleaner, needs acl fs).
  --force-renew             Force certbot to renew even if cert is valid > 30 days.
  --yes                     Assume yes on non-fatal confirmations.
  -h, --help                Show this help.
  -V, --version             Show script version.

Examples:
  sudo bash $0 \\
    --domain node.example.com \\
    --email admin@example.com \\
    --password-file /root/.hysteria.pw \\
    --port 8443 --cert-mode acl
USAGE
}

# ---------- arg parsing ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)        DOMAIN="${2:-}"; shift 2 ;;
      --email)         EMAIL="${2:-}"; shift 2 ;;
      --password)      PASSWORD="${2:-}"; shift 2 ;;
      --password-file) PASSWORD_FILE="${2:-}"; shift 2 ;;
      --port)          PORT="${2:-8443}"; shift 2 ;;
      --webroot)       WEBROOT="${2:-}"; shift 2 ;;
      --site-title)    SITE_TITLE="${2:-}"; shift 2 ;;
      --cert-mode)     CERT_MODE="${2:-copy}"; shift 2 ;;
      --force-renew)   FORCE_RENEW="1"; shift ;;
      --yes|-y)        ASSUME_YES="1"; shift ;;
      -V|--version)    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

validate_inputs() {
  [[ -n "$DOMAIN" ]] || die "--domain is required"
  [[ -n "$EMAIL"  ]] || die "--email is required"

  # basic FQDN sanity: letters/digits/dots/hyphens, at least one dot, no leading/trailing dot.
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "--domain does not look like a valid FQDN: $DOMAIN"

  [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "--email does not look valid: $EMAIL"

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
  (( PORT >= 1 && PORT <= 65535 )) || die "--port out of range: $PORT"

  case "$CERT_MODE" in
    copy|acl) ;;
    *) die "--cert-mode must be 'copy' or 'acl'" ;;
  esac

  if [[ -n "$PASSWORD_FILE" ]]; then
    [[ -r "$PASSWORD_FILE" ]] || die "--password-file not readable: $PASSWORD_FILE"
    PASSWORD="$(head -n1 "$PASSWORD_FILE" | tr -d '\r\n')"
    [[ -n "$PASSWORD" ]] || die "password file is empty: $PASSWORD_FILE"
  fi

  if [[ -z "$PASSWORD" ]]; then
    # Read from /dev/tty directly so the prompt works even when stdin is
    # busy (e.g. `curl … | sudo bash -s -- …`) or not a TTY.
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      printf 'Hysteria password: ' >/dev/tty
      IFS= read -r -s PASSWORD </dev/tty
      printf '\n' >/dev/tty
      [[ -n "$PASSWORD" ]] || die "empty password"
    else
      die "--password or --password-file is required (no TTY available for interactive prompt)"
    fi
  fi

  [[ -z "$WEBROOT" ]] && WEBROOT="/var/www/${DOMAIN}"

  log "version:  ${SCRIPT_VERSION}"
  log "domain:   ${DOMAIN}"
  log "email:    ${EMAIL}"
  log "port:     ${PORT}/udp"
  log "webroot:  ${WEBROOT}"
  log "certmode: ${CERT_MODE}"
  log "password: $(mask_secret "$PASSWORD")"
}

# ---------- environment ----------
require_root() {
  (( EUID == 0 )) || die "run as root: sudo bash $0 ..."
}

detect_os() {
  command -v apt-get >/dev/null 2>&1 || die "only apt-based systems (Debian/Ubuntu) are supported"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "os: ${PRETTY_NAME:-unknown}"
  fi
}

install_base_packages() {
  log "installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  local pkgs=(curl wget ca-certificates nginx certbot python3-certbot-nginx jq dnsutils ufw openssl)
  if [[ "$CERT_MODE" == "acl" ]]; then
    pkgs+=(acl)
  fi
  apt-get install -y "${pkgs[@]}"
}

get_public_ip() {
  local ip
  ip="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

preflight_dns() {
  log "checking DNS for ${DOMAIN}..."
  local pub
  pub="$(get_public_ip)"
  [[ -n "$pub" ]] || die "cannot determine public IPv4 address (no network?)"

  local -a a_records=()
  mapfile -t a_records < <(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' || true)
  if (( ${#a_records[@]} == 0 )); then
    err "no A record found for ${DOMAIN}"
    die  "set DNS A record to ${pub} and wait for propagation before re-running"
  fi

  local r match=0
  for r in "${a_records[@]}"; do
    [[ "$r" == "$pub" ]] && { match=1; break; }
  done

  if (( match == 0 )); then
    err "DNS A record(s) for ${DOMAIN}: ${a_records[*]}"
    err "this VPS public IPv4:        ${pub}"
    die "A record does not point to this VPS; Certbot HTTP-01 will fail"
  fi

  log "DNS OK: ${DOMAIN} → ${pub}"
}

# ---------- backup ----------
backup_existing_configs() {
  BACKUP_DIR="/root/${SCRIPT_NAME}-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  if [[ -d /etc/nginx ]]; then
    cp -a /etc/nginx "$BACKUP_DIR/nginx"
  fi
  if [[ -d /etc/hysteria ]]; then
    cp -a /etc/hysteria "$BACKUP_DIR/hysteria"
  fi
  if [[ -d /etc/letsencrypt ]]; then
    # metadata only; skip archive/ to save space and avoid key duplication
    mkdir -p "$BACKUP_DIR/letsencrypt-meta"
    [[ -d /etc/letsencrypt/renewal ]] && cp -a /etc/letsencrypt/renewal "$BACKUP_DIR/letsencrypt-meta/"
    [[ -d /etc/letsencrypt/renewal-hooks ]] && cp -a /etc/letsencrypt/renewal-hooks "$BACKUP_DIR/letsencrypt-meta/"
  fi
  log "existing configs backed up to: ${BACKUP_DIR}"
}

# ---------- firewall ----------
configure_firewall() {
  log "configuring ufw..."
  ufw allow 22/tcp   comment 'ssh'   >/dev/null
  ufw allow 80/tcp   comment 'http'  >/dev/null
  ufw allow 443/tcp  comment 'https' >/dev/null
  ufw allow "${PORT}/udp" comment 'hysteria' >/dev/null

  # Verify the SSH rule is queued before enabling — if we lose SSH here, recovery is painful.
  if ! ufw show added 2>/dev/null | grep -qE "allow +22/tcp"; then
    die "ufw rule for 22/tcp was not queued; refusing to enable firewall"
  fi

  ufw --force enable >/dev/null
  log "ufw enabled with rules: 22/tcp, 80/tcp, 443/tcp, ${PORT}/udp"
}

# ---------- nginx: HTTP (pre-LE) ----------
write_http_site() {
  log "writing HTTP vhost for ACME challenge..."
  install -d -m 755 "$WEBROOT"

  local public_ip generated_at
  public_ip="$(get_public_ip)"
  generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  local e_domain e_title e_ip e_gen e_port
  e_domain="$(html_escape "$DOMAIN")"
  e_title="$(html_escape "$SITE_TITLE")"
  e_ip="$(html_escape "${public_ip:-unknown}")"
  e_gen="$(html_escape "$generated_at")"
  e_port="$(html_escape "$PORT")"

  cat > "${WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <title>${e_domain}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root{--bg-1:#07122f;--bg-2:#0b1d4e;--card:rgba(19,31,66,.9);--card-2:rgba(255,255,255,.04);--line:rgba(255,255,255,.08);--text:#fff;--muted:#b8c4da;--success:#22c55e;--shadow:0 20px 60px rgba(0,0,0,.35);--radius:28px}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Arial,sans-serif;background:radial-gradient(circle at top left,rgba(96,165,250,.16),transparent 28%),radial-gradient(circle at top right,rgba(125,211,252,.12),transparent 24%),linear-gradient(180deg,var(--bg-2),var(--bg-1));display:grid;place-items:center;padding:28px}
    .panel{width:min(100%,760px);background:var(--card);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);backdrop-filter:blur(10px);overflow:hidden}
    .topbar{display:flex;align-items:center;justify-content:space-between;padding:18px 22px;border-bottom:1px solid var(--line);background:rgba(255,255,255,.02)}
    .brand{display:flex;align-items:center;gap:12px;min-width:0}
    .brand-dot{width:12px;height:12px;border-radius:999px;background:linear-gradient(135deg,#22c55e,#86efac);box-shadow:0 0 18px rgba(34,197,94,.7);flex:0 0 auto}
    .brand-title{font-size:14px;font-weight:700;letter-spacing:.06em;color:var(--muted);text-transform:uppercase;white-space:nowrap}
    .status{display:inline-flex;align-items:center;gap:8px;padding:8px 12px;border-radius:999px;background:rgba(34,197,94,.12);border:1px solid rgba(34,197,94,.22);font-size:13px;font-weight:700;color:#dcfce7;white-space:nowrap}
    .status::before{content:"";width:8px;height:8px;border-radius:999px;background:#22c55e;box-shadow:0 0 12px rgba(34,197,94,.8)}
    .content{padding:34px 28px 28px}
    .hero{display:grid;gap:12px;margin-bottom:28px}
    .domain{margin:0;font-size:clamp(28px,5vw,48px);line-height:1.02;font-weight:800;letter-spacing:-.03em;word-break:break-word}
    .subtitle{margin:0;color:var(--muted);font-size:18px;line-height:1.5}
    .grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:22px}
    .item{background:var(--card-2);border:1px solid var(--line);border-radius:18px;padding:16px 16px 14px}
    .label{font-size:12px;line-height:1.2;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-bottom:10px}
    .value{font-size:19px;line-height:1.35;font-weight:700;color:var(--text);word-break:break-word}
    .footer{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:18px;color:var(--muted);font-size:14px}
    .footer strong{color:var(--text);font-weight:700}
    @media (max-width:680px){.grid{grid-template-columns:1fr}.topbar{flex-direction:column;align-items:flex-start;gap:12px}}
  </style>
</head>
<body>
  <section class="panel">
    <div class="topbar">
      <div class="brand"><div class="brand-dot"></div><div class="brand-title">Infrastructure Node</div></div>
      <div class="status">ONLINE</div>
    </div>
    <div class="content">
      <div class="hero">
        <h1 class="domain">${e_domain}</h1>
        <p class="subtitle">${e_title}</p>
      </div>
      <div class="grid">
        <div class="item"><div class="label">Server IP</div><div class="value">${e_ip}</div></div>
        <div class="item"><div class="label">Hysteria Port</div><div class="value">${e_port}/udp</div></div>
        <div class="item"><div class="label">TLS SNI</div><div class="value">${e_domain}</div></div>
        <div class="item"><div class="label">Environment</div><div class="value">Nginx + Hysteria 2</div></div>
      </div>
      <div class="footer">
        <div>Generated: <strong>${e_gen}</strong></div>
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

    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF

  ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

# ---------- certbot ----------
cert_valid_for_days() {
  local pem="$1" days="$2"
  openssl x509 -checkend $((days * 86400)) -noout -in "$pem" >/dev/null 2>&1
}

issue_certificate() {
  local live="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

  if [[ "$FORCE_RENEW" != "1" && -f "$live" ]] && cert_valid_for_days "$live" 30; then
    log "existing LE certificate is valid >30 days — skipping issuance"
    return 0
  fi

  log "requesting Let's Encrypt certificate (HTTP-01 via nginx)..."
  certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL" \
    --redirect \
    --keep-until-expiring
}

# ---------- nginx: HTTPS (post-LE, hardened) ----------
write_https_site() {
  log "writing hardened HTTPS vhost..."
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

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;

    # Modern TLS: TLS 1.2+1.3 only, AEAD ciphers, no session tickets.
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Permissions-Policy "interest-cohort=()" always;

    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF

  nginx -t
  systemctl reload nginx
}

# ---------- hysteria install ----------
install_hysteria() {
  if command -v hysteria >/dev/null 2>&1; then
    log "hysteria already installed: $(hysteria version 2>/dev/null | head -n1 || echo unknown)"
    return 0
  fi

  log "installing Hysteria 2 via upstream installer..."
  local tmp
  tmp="$(mktemp)"
  # Upstream installer is fetched to a file so we can sanity-check it before exec.
  curl -fsSL --max-time 30 "$HYSTERIA_INSTALLER_URL" -o "$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "empty installer from $HYSTERIA_INSTALLER_URL"; }
  head -n1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "installer is not a shell script"; }
  bash "$tmp"
  rm -f "$tmp"

  command -v hysteria >/dev/null 2>&1 || die "hysteria binary missing after install"
  id -u hysteria >/dev/null 2>&1 || die "system user 'hysteria' not created by installer"
  log "hysteria installed: $(hysteria version 2>/dev/null | head -n1 || echo unknown)"
}

# ---------- cert delivery: copy mode ----------
setup_certs_copy() {
  log "cert-mode=copy: mirroring LE certs into /etc/hysteria/certs"
  local le="/etc/letsencrypt/live/${DOMAIN}"
  [[ -r "${le}/fullchain.pem" && -r "${le}/privkey.pem" ]] \
    || die "LE cert files missing at ${le}"

  install -d -m 755 /etc/hysteria/certs
  cp -f "${le}/fullchain.pem" /etc/hysteria/certs/fullchain.pem
  cp -f "${le}/privkey.pem"   /etc/hysteria/certs/privkey.pem
  chown -R hysteria:hysteria  /etc/hysteria/certs
  chmod 755 /etc/hysteria
  chmod 755 /etc/hysteria/certs
  chmod 640 /etc/hysteria/certs/fullchain.pem
  chmod 640 /etc/hysteria/certs/privkey.pem

  install_certbot_deploy_hook_copy
  HYSTERIA_CERT_PATH="/etc/hysteria/certs/fullchain.pem"
  HYSTERIA_KEY_PATH="/etc/hysteria/certs/privkey.pem"
}

install_certbot_deploy_hook_copy() {
  log "installing certbot deploy-hook (refresh cert copies on renewal)..."
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  local hook="/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync-${DOMAIN}.sh"
  cat > "$hook" <<HOOK
#!/bin/sh
set -eu
if [ "\${RENEWED_LINEAGE:-}" != "/etc/letsencrypt/live/${DOMAIN}" ]; then
  exit 0
fi
LE="/etc/letsencrypt/live/${DOMAIN}"
[ -r "\${LE}/fullchain.pem" ] && [ -r "\${LE}/privkey.pem" ] || exit 1
install -d -m 755 /etc/hysteria/certs
cp -f "\${LE}/fullchain.pem" /etc/hysteria/certs/fullchain.pem
cp -f "\${LE}/privkey.pem"   /etc/hysteria/certs/privkey.pem
chown -R hysteria:hysteria   /etc/hysteria/certs
chmod 640 /etc/hysteria/certs/fullchain.pem /etc/hysteria/certs/privkey.pem
systemctl reload-or-restart hysteria-server
HOOK
  chmod +x "$hook"
}

# ---------- cert delivery: ACL mode ----------
setup_certs_acl() {
  log "cert-mode=acl: granting hysteria user read access via POSIX ACL"

  if ! command -v setfacl >/dev/null 2>&1; then
    warn "setfacl not available; falling back to copy mode"
    CERT_MODE="copy"; setup_certs_copy; return
  fi

  # Probe whether the filesystem actually supports ACLs for our target path.
  local probe="/etc/letsencrypt/.hysteria-acl-probe.$$"
  : > "$probe" 2>/dev/null || { warn "cannot write probe; falling back to copy mode"; CERT_MODE="copy"; setup_certs_copy; return; }
  if ! setfacl -m u:hysteria:r "$probe" 2>/dev/null; then
    rm -f "$probe"
    warn "filesystem does not support POSIX ACL on /etc/letsencrypt; falling back to copy mode"
    CERT_MODE="copy"; setup_certs_copy; return
  fi
  rm -f "$probe"

  # Traverse bit on each directory in the chain. 'x' without 'r' = can enter, cannot list.
  setfacl -m u:hysteria:x /etc/letsencrypt/live
  setfacl -m u:hysteria:x /etc/letsencrypt/archive
  setfacl -m u:hysteria:x "/etc/letsencrypt/live/${DOMAIN}"
  setfacl -m u:hysteria:x "/etc/letsencrypt/archive/${DOMAIN}"

  # Read bit on every existing versioned cert file.
  local f
  for f in /etc/letsencrypt/archive/"${DOMAIN}"/privkey*.pem \
           /etc/letsencrypt/archive/"${DOMAIN}"/fullchain*.pem \
           /etc/letsencrypt/archive/"${DOMAIN}"/chain*.pem \
           /etc/letsencrypt/archive/"${DOMAIN}"/cert*.pem; do
    [[ -f "$f" ]] && setfacl -m u:hysteria:r "$f"
  done

  # Default ACL — applies to files created by future certbot renewals.
  setfacl -d -m u:hysteria:r "/etc/letsencrypt/archive/${DOMAIN}"

  # Ground truth: can hysteria actually read the live symlinks?
  if ! sudo -u hysteria test -r "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
     || ! sudo -u hysteria test -r "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"; then
    err "ACL verification failed: hysteria user cannot read LE certs"
    warn "falling back to copy mode"
    CERT_MODE="copy"; setup_certs_copy; return
  fi

  # In ACL mode we still install a minimal deploy-hook that only reloads hysteria.
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  local hook="/etc/letsencrypt/renewal-hooks/deploy/hysteria-reload-${DOMAIN}.sh"
  cat > "$hook" <<HOOK
#!/bin/sh
set -eu
if [ "\${RENEWED_LINEAGE:-}" != "/etc/letsencrypt/live/${DOMAIN}" ]; then
  exit 0
fi
systemctl reload-or-restart hysteria-server
HOOK
  chmod +x "$hook"

  HYSTERIA_CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  HYSTERIA_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  log "ACL mode active; hysteria reads certs directly from /etc/letsencrypt/live/${DOMAIN}"
}

setup_hysteria_certs() {
  case "$CERT_MODE" in
    copy) setup_certs_copy ;;
    acl)  setup_certs_acl  ;;
  esac
}

# ---------- hysteria config ----------
write_hysteria_config() {
  log "writing /etc/hysteria/config.yaml (password masked in logs)"
  install -d -m 755 /etc/hysteria
  local cfg="/etc/hysteria/config.yaml"
  umask 077
  cat > "$cfg" <<EOF
listen: :${PORT}

tls:
  cert: ${HYSTERIA_CERT_PATH}
  key: ${HYSTERIA_KEY_PATH}

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
  umask 022

  chown root:hysteria "$cfg"
  chmod 640 "$cfg"
  log "config written: $cfg (owner root:hysteria, mode 640, password: $(mask_secret "$PASSWORD"))"
}

ensure_hysteria_restart_policy() {
  log "installing systemd drop-in: Restart=always, RestartSec=5"
  install -d -m 755 /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
  systemctl daemon-reload
}

start_hysteria() {
  log "starting hysteria-server..."
  systemctl enable hysteria-server >/dev/null 2>&1 || true
  systemctl restart hysteria-server
  sleep 2
}

# ---------- verification ----------
verify_services() {
  log "verifying nginx..."
  systemctl is-active --quiet nginx || die "nginx is not active"

  log "verifying hysteria-server..."
  if ! systemctl is-active --quiet hysteria-server; then
    err "hysteria-server is not active"
    journalctl -u hysteria-server -n 30 --no-pager -l || true
    die "hysteria-server failed to start"
  fi

  log "verifying UDP listener on :${PORT}..."
  if ! ss -ulnp 2>/dev/null | grep -q ":${PORT}"; then
    err "no UDP listener on :${PORT}"
    journalctl -u hysteria-server -n 30 --no-pager -l || true
    ss -ulnp || true
    die "hysteria is not listening"
  fi

  log "verifying cert access by hysteria user..."
  if ! sudo -u hysteria test -r "$HYSTERIA_CERT_PATH" \
     || ! sudo -u hysteria test -r "$HYSTERIA_KEY_PATH"; then
    die "hysteria user cannot read TLS material at ${HYSTERIA_CERT_PATH}"
  fi

  log "verifying HTTPS responds locally..."
  if ! curl -fsSI --max-time 5 "https://${DOMAIN}" >/dev/null 2>&1; then
    warn "HTTPS probe to https://${DOMAIN} failed (DNS/firewall/propagation?)"
  fi

  log "all checks passed"
}

# ---------- summary ----------
print_summary() {
  local public_ip
  public_ip="$(get_public_ip)"

  printf '\n%s==================== RESULT ====================%s\n' "$BLU" "$NC"
  printf 'Script version:      %s\n' "$SCRIPT_VERSION"
  printf 'Domain:              %s\n' "$DOMAIN"
  printf 'Public IP:           %s\n' "${public_ip:-unknown}"
  printf 'Website:             https://%s\n' "$DOMAIN"
  printf 'Hysteria endpoint:   %s:%s/udp\n' "$DOMAIN" "$PORT"
  printf 'TLS SNI:             %s\n' "$DOMAIN"
  printf 'Cert mode:           %s\n' "$CERT_MODE"
  printf 'Hysteria cert:       %s\n' "$HYSTERIA_CERT_PATH"
  printf 'Hysteria key:        %s\n' "$HYSTERIA_KEY_PATH"
  printf 'Config:              /etc/hysteria/config.yaml (mode 640, root:hysteria)\n'
  printf 'Backup of old cfgs:  %s\n' "$BACKUP_DIR"
  printf 'Password:            %s\n' "$PASSWORD"
  printf '\nSuggested Surge / client node:\n'
  printf '  Protocol:          Hysteria 2\n'
  printf '  Server Address:    %s\n' "${public_ip:-$DOMAIN}"
  printf '  Port:              %s\n' "$PORT"
  printf '  Password:          %s\n' "$PASSWORD"
  printf '  Custom TLS SNI:    %s\n' "$DOMAIN"
  printf '\nUseful checks:\n'
  printf '  systemctl status hysteria-server --no-pager -l\n'
  printf '  journalctl -u hysteria-server -f --no-pager\n'
  printf '  curl -I https://%s\n' "$DOMAIN"
  printf '  ss -ulnp | grep :%s\n' "$PORT"
  printf '%s================================================%s\n' "$BLU" "$NC"
}

# ---------- main ----------
main() {
  parse_args "$@"
  validate_inputs
  require_root
  detect_os
  install_base_packages
  preflight_dns
  backup_existing_configs
  configure_firewall
  write_http_site
  issue_certificate
  write_https_site
  install_hysteria
  setup_hysteria_certs
  write_hysteria_config
  ensure_hysteria_restart_policy
  start_hysteria
  verify_services
  print_summary
}

main "$@"
