#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone Debian/Ubuntu bootstrap for Hysteria 2, nginx and Let's Encrypt.
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"
SCRIPT_NAME="hysteria-vps-bootstrap"
HYSTERIA_INSTALLER_URL="https://raw.githubusercontent.com/apernet/hysteria/master/scripts/install_server.sh"
DOMAIN="" EMAIL="" PASSWORD="" PASSWORD_FILE="" PORT="8443" WEBROOT=""
SITE_TITLE="Инфраструктурный узел активен."
CERT_MODE="copy" FORCE_RENEW=0 UFW_MODE="keep" SHOW_PASSWORD=0
IPV6_AVAILABLE=0 BACKUP_DIR="" WORK_DIR="" PUBLIC_IP=""
HYSTERIA_CERT_PATH="" HYSTERIA_KEY_PATH=""
SSH_PORTS=()
ROLLBACK_HYSTERIA=0 HYSTERIA_WAS_ACTIVE=0 HYSTERIA_WAS_ENABLED=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}
Usage: sudo bash $0 --domain <fqdn> --email <addr> [options]
  --password-file <path>  Password from first line (preferred for automation).
  --password <value>      Password (visible in process arguments).
                         If omitted, reuse existing password or prompt via /dev/tty.
  --port <udp>           Hysteria UDP port (default 8443).
  --webroot <path>       Absolute site path (default /var/www/<domain>).
  --site-title <text>    Status page subtitle.
  --cert-mode copy|acl   Certificate delivery (default copy).
  --force-renew          Explicitly force certificate renewal.
  --ufw keep|enable|skip Default keep: add web rules only if UFW is already active.
  --ssh-port <tcp>       Additional SSH port to allow; repeatable.
                         Required with --ufw enable if SSH cannot be detected.
  --show-password        Include password in final output (default hidden).
  --yes, -y              Accepted for compatibility; does not enable UFW.
  --help, -h             Show help.
  --version, -V          Show version.
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --domain|--email|--password|--password-file|--port|--webroot|--site-title|--cert-mode|--ufw|--ssh-port)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then die "missing value for $1"; fi
        case "$1" in
          --domain) DOMAIN="$2" ;; --email) EMAIL="$2" ;;
          --password) PASSWORD="$2" ;; --password-file) PASSWORD_FILE="$2" ;;
          --port) PORT="$2" ;; --webroot) WEBROOT="$2" ;;
          --site-title) SITE_TITLE="$2" ;; --cert-mode) CERT_MODE="$2" ;;
          --ufw) UFW_MODE="$2" ;; --ssh-port) SSH_PORTS+=("$2") ;;
        esac
        shift 2 ;;
      --force-renew) FORCE_RENEW=1; shift ;;
      --show-password) SHOW_PASSWORD=1; shift ;;
      --yes|-y) shift ;;
      --help|-h) usage; exit 0 ;;
      --version|-V) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
validate_inputs() {
  if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || (( ${#DOMAIN} > 253 )); then die "--domain must be a valid FQDN"; fi
  DOMAIN="${DOMAIN,,}"
  local label p
  local -a labels
  IFS=. read -r -a labels <<< "$DOMAIN"
  for label in "${labels[@]}"; do (( ${#label} <= 63 )) || die "domain label too long"; done
  [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ && "$EMAIL" != -* ]] || die "invalid --email"
  valid_port "$PORT" || die "--port must be between 1 and 65535"
  PORT=$((10#$PORT))
  for p in "${SSH_PORTS[@]}"; do valid_port "$p" || die "invalid --ssh-port"; done
  case "$CERT_MODE" in copy|acl) ;; *) die "--cert-mode must be copy or acl" ;; esac
  case "$UFW_MODE" in keep|enable|skip) ;; *) die "--ufw must be keep, enable or skip" ;; esac
  [[ -z "$PASSWORD" || -z "$PASSWORD_FILE" ]] || die "use only one password option"
  WEBROOT="${WEBROOT:-/var/www/$DOMAIN}"
  # These values enter nginx and a root-owned renewal hook, so restrict metacharacters.
  [[ "$WEBROOT" =~ ^/[A-Za-z0-9_./-]+$ && "$WEBROOT" != / && "$WEBROOT" != *'/../'* && "$WEBROOT" != */.. ]] \
    || die "--webroot must be an absolute path without spaces, '..' or shell/nginx metacharacters"
}

restore_package_policy() {
  local policy=/usr/sbin/policy-rc.d saved=/usr/sbin/policy-rc.d.hysteria-backup
  if [[ -f "$policy" ]] && grep -q '^# hysteria-bootstrap temporary policy$' "$policy"; then
    rm -f "$policy"
  fi
  if [[ ! -e "$policy" && ! -L "$policy" && ( -e "$saved" || -L "$saved" ) ]]; then
    mv "$saved" "$policy"
  fi
}
cleanup() {
  local rc=$?
  trap - EXIT
  if (( ROLLBACK_HYSTERIA )); then rollback_hysteria; fi
  restore_package_policy
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  exit "$rc"
}
on_error() {
  local rc=$? line=$1
  printf '[ERROR] failed at line %s (exit %s). Backup: %s\n' "$line" "$rc" "${BACKUP_DIR:-not created}" >&2
  printf 'Diagnostics: nginx -t; journalctl -u nginx -u hysteria-server -n 50 --no-pager\n' >&2
  exit "$rc"
}

require_environment() {
  (( EUID == 0 )) || die "run with sudo/root"
  if [[ "$(uname -s)" != Linux ]] || ! command -v apt-get >/dev/null; then die "Debian/Ubuntu Linux required"; fi
  [[ -d /run/systemd/system ]] || die "a running systemd is required"
  command -v flock >/dev/null || die "install util-linux (flock) first"
  exec 9>/run/lock/hysteria-vps-bootstrap.lock
  flock -n 9 || die "another bootstrap is running"
  umask 077
  WORK_DIR="$(mktemp -d /tmp/hysteria-bootstrap.XXXXXX)"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  trap 'on_error $LINENO' ERR
  restore_package_policy
}

backup_existing_configs() {
  BACKUP_DIR="$(mktemp -d "/root/${SCRIPT_NAME}-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  local dir
  for dir in nginx hysteria; do
    if [[ -d "/etc/$dir" ]]; then cp -a "/etc/$dir" "$BACKUP_DIR/$dir"; fi
  done
  mkdir -p "$BACKUP_DIR/letsencrypt-meta"
  for dir in renewal renewal-hooks; do
    if [[ -d "/etc/letsencrypt/$dir" ]]; then cp -a "/etc/letsencrypt/$dir" "$BACKUP_DIR/letsencrypt-meta/"; fi
  done
  if [[ -d /etc/systemd/system/hysteria-server.service.d ]]; then
    cp -a /etc/systemd/system/hysteria-server.service.d "$BACKUP_DIR/"
  fi
  log "backup: $BACKUP_DIR"
}

detect_ipv6() {
  IPV6_AVAILABLE=0
  [[ -r /proc/net/if_inet6 ]] && grep -q . /proc/net/if_inet6 || return 0
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]] || return 0
  if command -v python3 >/dev/null && python3 - <<'PY6'
import socket
try:
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
        s.bind(('::', 0))
except OSError:
    raise SystemExit(1)
PY6
  then IPV6_AVAILABLE=1; fi
}

repair_ipv6_file() {
  local file=$1 tmp
  [[ -f "$file" ]] || return 0
  # Only standalone wildcard IPv6 listeners. Never delete an inline server block.
  tmp="$(mktemp)"
  sed -E '/^[[:space:]]*listen[[:space:]]+\[::\]:[0-9]+[^;]*;[[:space:]]*(#.*)?$/d' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then cat "$tmp" > "$file"; fi
  rm -f "$tmp"
}
repair_nginx_ipv6() {
  (( IPV6_AVAILABLE == 0 )) || return 0
  repair_ipv6_file /etc/nginx/sites-available/default
  repair_ipv6_file "/etc/nginx/sites-available/$DOMAIN"
}

install_base_packages() {
  log "repairing package state and installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  # Prevent nginx's postinst from starting its new IPv6 default before it is repaired.
  # Other service requests are delegated to any original local policy.
  local policy=/usr/sbin/policy-rc.d saved=/usr/sbin/policy-rc.d.hysteria-backup
  [[ ! -e "$saved" && ! -L "$saved" ]] || die "unresolved package policy backup: $saved"
  if [[ -e "$policy" || -L "$policy" ]]; then mv "$policy" "$saved"; fi
  cat > "$policy" <<'POLICY'
#!/bin/sh
# hysteria-bootstrap temporary policy
case "${1:-}" in nginx|nginx.service) exit 101 ;; esac
if [ -x /usr/sbin/policy-rc.d.hysteria-backup ]; then
  exec /usr/sbin/policy-rc.d.hysteria-backup "$@"
fi
exit 0
POLICY
  chmod 755 "$policy"
  repair_nginx_ipv6
  if ! dpkg --configure -a; then
    apt-get -o DPkg::Lock::Timeout=120 -f install -y
    dpkg --configure -a
  fi
  apt-get -o DPkg::Lock::Timeout=120 update
  local pkgs=(ca-certificates curl nginx certbot dnsutils ufw openssl python3 python3-yaml iproute2 util-linux)
  [[ "$CERT_MODE" != acl ]] || pkgs+=(acl)
  apt-get -o DPkg::Lock::Timeout=120 install -y "${pkgs[@]}"
  detect_ipv6
  repair_nginx_ipv6
  restore_package_policy
  nginx -t || die "nginx configuration is invalid; check unrelated sites (backup: $BACKUP_DIR)"
  log "IPv6 listeners available: $IPV6_AVAILABLE"
}

load_password() {
  if [[ -n "$PASSWORD_FILE" ]]; then
    [[ -f "$PASSWORD_FILE" && -r "$PASSWORD_FILE" ]] || die "password file is not readable"
    IFS= read -r PASSWORD < "$PASSWORD_FILE" || [[ -n "$PASSWORD" ]]
    PASSWORD="${PASSWORD%$'\r'}"
  elif [[ -z "$PASSWORD" && -f /etc/hysteria/config.yaml ]]; then
    PASSWORD="$(python3 - <<'PY_PASSWORD'
import yaml
with open('/etc/hysteria/config.yaml') as f:
    c = yaml.safe_load(f)
a = c.get('auth', {})
if a.get('type') != 'password' or not isinstance(a.get('password'), str):
    raise SystemExit('Existing config has no string password; provide --password-file explicitly.')
print(a['password'], end='')
PY_PASSWORD
)"
    log "reusing existing Hysteria password"
  elif [[ -z "$PASSWORD" ]]; then
    if { exec 3<>/dev/tty; } 2>/dev/null; then
      printf 'Hysteria password: ' >&3
      IFS= read -r -s PASSWORD <&3 || true
      printf '\n' >&3
      exec 3>&-
    else die "no terminal; provide --password-file"; fi
  fi
  [[ -n "$PASSWORD" && "$PASSWORD" != *$'\n'* && "$PASSWORD" != *$'\r'* ]] || die "password must be nonempty and single-line"
}

get_public_ip() {
  curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org \
    || curl -4 -fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip
}
preflight_dns() {
  PUBLIC_IP="$(get_public_ip)"
  local a aaaa
  a="$(dig +time=3 +tries=2 +short A "$DOMAIN")"
  aaaa="$(dig +time=3 +tries=2 +short AAAA "$DOMAIN")"
  PUBLIC_IP="$PUBLIC_IP" A_RECORDS="$a" AAAA_RECORDS="$aaaa" IPV6_AVAILABLE="$IPV6_AVAILABLE" python3 - <<'PY_DNS'
import ipaddress, json, os, subprocess
public = ipaddress.IPv4Address(os.environ['PUBLIC_IP'])
def records(value, version):
    result = []
    for line in value.splitlines():
        try:
            address = ipaddress.ip_address(line.strip())
            if address.version == version:
                result.append(address)
        except ValueError:
            pass  # dig +short can include CNAME names
    return result
v4 = records(os.environ['A_RECORDS'], 4)
v6 = records(os.environ['AAAA_RECORDS'], 6)
if not v4 or any(x != public for x in v4):
    raise SystemExit('Every DNS A record must point to this VPS: ' + str(public))
if v6:
    if os.environ['IPV6_AVAILABLE'] != '1':
        raise SystemExit('Remove the DNS AAAA record: IPv6 is unavailable on this VPS.')
    local = json.loads(subprocess.check_output(['ip', '-j', '-6', 'addr', 'show', 'scope', 'global']))
    addresses = {ipaddress.ip_address(a['local']) for i in local for a in i.get('addr_info', [])}
    if any(a not in addresses for a in v6):
        raise SystemExit('Every DNS AAAA record must be assigned to this VPS.')
PY_DNS
  log "DNS validated for $DOMAIN ($PUBLIC_IP); external firewall must allow HTTP-01 on TCP 80"
}

discover_ssh_ports() {
  local port config
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r _ _ _ port <<< "$SSH_CONNECTION"
    valid_port "$port" || die "invalid SSH_CONNECTION server port"
    SSH_PORTS+=("$port")
  fi
  if command -v sshd >/dev/null; then
    config="$(sshd -T 2>/dev/null)" || die "cannot read sshd configuration; fix sshd -T before enabling UFW"
    while read -r port; do [[ -z "$port" ]] || SSH_PORTS+=("$port"); done < <(awk '$1 == "port" {print $2}' <<< "$config")
  fi
  # Include actual listeners (socket-activated sshd may differ from sshd_config).
  while read -r port; do [[ -z "$port" ]] || SSH_PORTS+=("$port"); done < <(
    ss -H -ltnp | awk '/"sshd"|"sshd-session"/ {n=split($4,a,":"); print a[n]}')
  if systemctl is-active --quiet ssh.socket; then
    while read -r port; do [[ -z "$port" ]] || SSH_PORTS+=("$port"); done < <(
      systemctl show ssh.socket -p Listen --value | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}')
  fi
  (( ${#SSH_PORTS[@]} )) || die "cannot determine SSH ports; pass --ssh-port before --ufw enable"
  for port in "${SSH_PORTS[@]}"; do valid_port "$port" || die "invalid detected SSH port"; done
}
configure_firewall() {
  [[ "$UFW_MODE" != skip ]] || { log "UFW unchanged (--ufw skip)"; return; }
  local status port
  status="$(LC_ALL=C ufw status)" || die "cannot determine UFW status"
  if [[ "$status" != *'Status: active'* && "$UFW_MODE" == keep ]]; then
    log "UFW is inactive; leaving it inactive (use --ufw enable to opt in)"
    return
  fi
  if [[ "$UFW_MODE" == enable ]]; then
    discover_ssh_ports
    # Insert before existing deny rules. Never reset rules or default policies.
    for port in "${SSH_PORTS[@]}"; do
      ufw prepend allow "$((10#$port))/tcp" comment 'hysteria-bootstrap SSH'
    done
  fi
  ufw allow 80/tcp comment 'hysteria-bootstrap HTTP'
  ufw allow 443/tcp comment 'hysteria-bootstrap HTTPS'
  ufw allow "$PORT/udp" comment 'hysteria-bootstrap QUIC'
  if [[ "$UFW_MODE" == enable && "$status" != *'Status: active'* ]]; then ufw --force enable; fi
}

html_escape() {
  local s="${1:-}"
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"; s="${s//\'/\&#39;}"
  printf '%s' "$s"
}
write_status_page() {
  install -d -m 755 "$WEBROOT"
  # Preserve an existing site's content on repeat runs.
  [[ ! -e "$WEBROOT/index.html" ]] || return 0
  local public_ip generated_at
  public_ip="$PUBLIC_IP"
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
  chmod 644 "$WEBROOT/index.html"
}

certificate_usable() {
  local dir="/etc/letsencrypt/live/$DOMAIN" days=${1:-0} cert_pub key_pub
  [[ -r "$dir/fullchain.pem" && -r "$dir/privkey.pem" ]] || return 1
  openssl x509 -in "$dir/fullchain.pem" -noout -checkend "$((days * 86400))" >/dev/null 2>&1 || return 1
  openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || return 1
  cert_pub="$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout)" || return 1
  key_pub="$(openssl pkey -in "$dir/privkey.pem" -pubout)" || return 1
  [[ "$cert_pub" == "$key_pub" ]]
}

render_nginx_site() {
  local tls=$1 v6_http="" v6_https=""
  if (( IPV6_AVAILABLE )); then v6_http='listen [::]:80;'; v6_https='listen [::]:443 ssl http2;'; fi
  cat <<EOF
# Managed by hysteria-vps-bootstrap for $DOMAIN
server {
    listen 80;
    $v6_http
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
EOF
  if [[ "$tls" == 1 ]]; then
    cat <<EOF
    location / { return 301 https://$DOMAIN\$request_uri; }
}
server {
    listen 443 ssl http2;
    $v6_https
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:HysteriaSSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
EOF
  fi
  cat <<'EOF'
    location / { try_files $uri $uri/ =404; }
}
EOF
}

write_nginx_site() {
  local tls=$1 target="/etc/nginx/sites-available/$DOMAIN" link="/etc/nginx/sites-enabled/$DOMAIN"
  local old="$WORK_DIR/nginx.previous" had_old=0 had_link=0
  [[ ! -L "$target" ]] || die "refusing to overwrite symlink $target"
  if [[ -e "$target" ]]; then cp -a "$target" "$old"; had_old=1; fi
  if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" && "$(readlink -f "$link")" == "$target" ]] || die "unexpected nginx site link: $link"
    had_link=1
  fi
  render_nginx_site "$tls" > "$WORK_DIR/nginx.candidate"
  install -m 644 "$WORK_DIR/nginx.candidate" "$target"
  ln -sfn "$target" "$link"
  if nginx -t && systemctl reload-or-restart nginx; then
    systemctl enable nginx >/dev/null
    return
  fi
  if (( had_old )); then cp -a "$old" "$target"; else rm -f "$target"; fi
  if (( ! had_link )); then rm -f "$link"; fi
  if nginx -t; then systemctl reload-or-restart nginx || true; fi
  die "nginx activation failed; previous site restored"
}


validate_existing_lineage() {
  [[ ! -f "/etc/letsencrypt/renewal/$DOMAIN.conf" || "$FORCE_RENEW" == 1 ]] && return 0
  DOMAIN="$DOMAIN" WEBROOT="$WEBROOT" python3 - <<'PY_LINEAGE'
import os
from pathlib import Path
e = os.environ
settings = {}; mapping = {}; in_map = False
for line in Path('/etc/letsencrypt/renewal/' + e['DOMAIN'] + '.conf').read_text().splitlines():
    line = line.strip()
    if line.startswith('['):
        in_map = line == '[[webroot_map]]'
    elif '=' in line:
        k, v = line.split('=', 1)
        (mapping if in_map else settings)[k.strip()] = v.strip().strip(',').strip('"\'')
if settings.get('authenticator') == 'webroot':
    root = mapping.get(e['DOMAIN'], settings.get('webroot_path'))
    if root != e['WEBROOT']:
        raise SystemExit('Existing renewal uses another webroot. Keep that path or use --force-renew to update it.')
PY_LINEAGE
}

begin_hysteria_transaction() {
  local snapshot="$WORK_DIR/hysteria-transaction"
  mkdir -p "$snapshot/hooks"
  cp -a /etc/hysteria "$snapshot/hysteria"
  local hook
  for hook in hysteria-bootstrap.sh "hysteria-sync-$DOMAIN.sh" "hysteria-reload-$DOMAIN.sh"; do
    if [[ -e "/etc/letsencrypt/renewal-hooks/deploy/$hook" ]]; then
      cp -a "/etc/letsencrypt/renewal-hooks/deploy/$hook" "$snapshot/hooks/"
    fi
  done
  if [[ -f /etc/systemd/system/hysteria-server.service.d/bootstrap.conf ]]; then
    cp -a /etc/systemd/system/hysteria-server.service.d/bootstrap.conf "$snapshot/bootstrap.conf"
  fi
  if systemctl is-active --quiet hysteria-server; then HYSTERIA_WAS_ACTIVE=1; fi
  if systemctl is-enabled --quiet hysteria-server; then HYSTERIA_WAS_ENABLED=1; fi
  ROLLBACK_HYSTERIA=1
}
rollback_hysteria() {
  warn "restoring Hysteria config, certificate copies, renewal hooks and service state"
  local snapshot="$WORK_DIR/hysteria-transaction" hook
  systemctl stop hysteria-server || true
  cp -a "$snapshot/hysteria/." /etc/hysteria/
  if [[ ! -f "$snapshot/hysteria/config.yaml" ]]; then rm -f /etc/hysteria/config.yaml; fi
  for hook in hysteria-bootstrap.sh "hysteria-sync-$DOMAIN.sh" "hysteria-reload-$DOMAIN.sh"; do
    rm -f "/etc/letsencrypt/renewal-hooks/deploy/$hook"
    if [[ -f "$snapshot/hooks/$hook" ]]; then cp -a "$snapshot/hooks/$hook" /etc/letsencrypt/renewal-hooks/deploy/; fi
  done
  rm -f /etc/systemd/system/hysteria-server.service.d/bootstrap.conf
  if [[ -f "$snapshot/bootstrap.conf" ]]; then cp -a "$snapshot/bootstrap.conf" /etc/systemd/system/hysteria-server.service.d/; fi
  systemctl daemon-reload || true
  if (( ! HYSTERIA_WAS_ENABLED )); then systemctl disable hysteria-server || true; fi
  if (( HYSTERIA_WAS_ACTIVE )); then systemctl start hysteria-server || true; fi
}

issue_certificate() {
  local live="/etc/letsencrypt/live/$DOMAIN"
  # Refuse to replace an unrelated/mismatched lineage implicitly.
  if [[ -e "$live/fullchain.pem" ]] && ! certificate_usable 0; then
    openssl x509 -in "$live/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 \
      || die "existing certificate does not cover $DOMAIN; inspect the lineage before retrying"
  fi
  if [[ "$FORCE_RENEW" == 0 ]] && certificate_usable 30 && [[ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]]; then
    log "reusing certificate valid for more than 30 days"
  else
    local args=(certonly --webroot --webroot-path "$WEBROOT" --cert-name "$DOMAIN"
      -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL")
    if [[ "$FORCE_RENEW" == 1 ]]; then args+=(--force-renewal); else args+=(--keep-until-expiring); fi
    certbot "${args[@]}"
  fi
  certificate_usable 0 || die "certificate/key validation failed"
  systemctl enable --now certbot.timer
}

install_hysteria() {
  if ! command -v hysteria >/dev/null; then
    log "installing Hysteria 2 from the official installer"
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$HYSTERIA_INSTALLER_URL" -o "$WORK_DIR/install-hysteria.sh"
    bash -n "$WORK_DIR/install-hysteria.sh"
    HYSTERIA_USER=hysteria bash "$WORK_DIR/install-hysteria.sh"
  fi
  local version
  version="$(hysteria version)"
  grep -qE '^Version:[[:space:]]+v2\.' <<< "$version" || die "Hysteria 2 required; refusing to reuse a v1/unknown binary"
  id hysteria >/dev/null || die "hysteria system user missing; repair upstream installation first"
  [[ "$(systemctl show hysteria-server -p LoadState --value)" == loaded ]] || die "hysteria-server unit missing"
  [[ "$(systemctl show hysteria-server -p User --value)" == hysteria ]] || die "hysteria-server must use the hysteria user"
  [[ "$(systemctl show hysteria-server -p Group --value)" == hysteria ]] || die "hysteria-server must use the hysteria group"
  install -d -m 750 -o root -g hysteria /etc/hysteria
}

install_certbot_deploy_hook() {
  local hook=/etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  # A single Hysteria service has one certificate source. Remove the two legacy
  # hooks for this domain so copy/ACL transitions never leave competing hooks.
  rm -f "/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync-$DOMAIN.sh" \
        "/etc/letsencrypt/renewal-hooks/deploy/hysteria-reload-$DOMAIN.sh"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\n'
    printf 'DOMAIN=%q\nCERT_MODE=%q\n' "$DOMAIN" "$CERT_MODE"
    cat <<'HOOK'
[[ "${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/$DOMAIN" ]] || exit 0
exec 8>/run/lock/hysteria-certificate.lock
flock -w 120 8
LE="$RENEWED_LINEAGE"
openssl x509 -in "$LE/fullchain.pem" -noout -checkend 0 >/dev/null
openssl x509 -in "$LE/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null
cert_pub="$(openssl x509 -in "$LE/fullchain.pem" -pubkey -noout)"
key_pub="$(openssl pkey -in "$LE/privkey.pem" -pubout)"
[[ "$cert_pub" == "$key_pub" ]] || { echo 'Certificate/key mismatch' >&2; exit 1; }
if [[ "$CERT_MODE" == copy ]]; then
  base=/etc/hysteria/certs
  install -d -m 750 -o root -g hysteria "$base"
  release="$(mktemp -d "$base/release.XXXXXX")"
  chown root:hysteria "$release"
  chmod 750 "$release"
  install -m 640 -o root -g hysteria "$LE/fullchain.pem" "$release/fullchain.pem"
  install -m 640 -o root -g hysteria "$LE/privkey.pem" "$release/privkey.pem"
  previous="$(readlink "$base/current" || true)"
  ln -s "${release##*/}" "$base/.current.$$"
  mv -Tf "$base/.current.$$" "$base/current"
  # Keep the previous pair for recovery, prune only older generated releases.
  for old in "$base"/release.*; do
    [[ "$old" == "$release" || "${old##*/}" == "$previous" ]] || rm -rf -- "$old"
  done
  cert="$base/current/fullchain.pem"; key="$base/current/privkey.pem"
else
  # Reapply ACLs after renewal: chmod in Certbot may mask inherited permissions.
  setfacl -m u:hysteria:x /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive \
    "$LE" "/etc/letsencrypt/archive/$DOMAIN"
  setfacl -m u:hysteria:r "$(readlink -f "$LE/fullchain.pem")" "$(readlink -f "$LE/privkey.pem")"
  cert="$LE/fullchain.pem"; key="$LE/privkey.pem"
fi
runuser -u hysteria -- test -r "$cert"
runuser -u hysteria -- test -r "$key"
if [[ "${HYSTERIA_BOOTSTRAP_SYNC_ONLY:-0}" != 1 ]]; then
  nginx -t
  if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
  # Do not start an intentionally stopped Hysteria service during renewal.
  if systemctl is-active --quiet hysteria-server; then systemctl restart hysteria-server; fi
fi
HOOK
  } > "$WORK_DIR/deploy-hook"
  bash -n "$WORK_DIR/deploy-hook"
  install -m 700 "$WORK_DIR/deploy-hook" "$hook"
}

setup_hysteria_certs() {
  if [[ "$CERT_MODE" == acl ]]; then
    local probe
    probe="$(mktemp /etc/letsencrypt/.acl-probe.XXXXXX)"
    if ! setfacl -m u:hysteria:r "$probe"; then
      warn "ACL unsupported; using copy mode"
      CERT_MODE=copy
    fi
    rm -f "$probe"
  fi
  install_certbot_deploy_hook
  if ! RENEWED_LINEAGE="/etc/letsencrypt/live/$DOMAIN" HYSTERIA_BOOTSTRAP_SYNC_ONLY=1 \
      /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh; then
    if [[ "$CERT_MODE" == acl ]]; then
      warn "ACL verification failed; using copy mode"
      CERT_MODE=copy
      install_certbot_deploy_hook
      RENEWED_LINEAGE="/etc/letsencrypt/live/$DOMAIN" HYSTERIA_BOOTSTRAP_SYNC_ONLY=1 \
        /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh
    else die "certificate delivery failed"; fi
  fi
  if [[ "$CERT_MODE" == copy ]]; then
    HYSTERIA_CERT_PATH=/etc/hysteria/certs/current/fullchain.pem
    HYSTERIA_KEY_PATH=/etc/hysteria/certs/current/privkey.pem
  else
    HYSTERIA_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    HYSTERIA_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  fi
}

render_hysteria_config() {
  PASSWORD="$PASSWORD" PORT="$PORT" IPV6_AVAILABLE="$IPV6_AVAILABLE" \
    HYSTERIA_CERT_PATH="$HYSTERIA_CERT_PATH" HYSTERIA_KEY_PATH="$HYSTERIA_KEY_PATH" WEBROOT="$WEBROOT" python3 - <<'PY_CONFIG'
import json, os
e = os.environ
# JSON is a YAML subset. Quotes, colons, hashes, booleans and Unicode passwords
# round-trip exactly; the secret is never interpolated into shell/YAML syntax.
print(json.dumps({
    'listen': (':' if e['IPV6_AVAILABLE'] == '1' else '0.0.0.0:') + e['PORT'],
    'tls': {'cert': e['HYSTERIA_CERT_PATH'], 'key': e['HYSTERIA_KEY_PATH']},
    'auth': {'type': 'password', 'password': e['PASSWORD']},
    'masquerade': {'type': 'file', 'file': {'dir': e['WEBROOT']}},
}, ensure_ascii=False, indent=2))
PY_CONFIG
}

udp_owned_by_hysteria() {
  local pid
  pid="$(systemctl show hysteria-server -p MainPID --value)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  ss -H -lunp "sport = :$PORT" | grep -q "pid=$pid,"
}
write_hysteria_config() {
  local cfg=/etc/hysteria/config.yaml candidate=/etc/hysteria/.bootstrap-candidate.yaml
  local previous="$WORK_DIR/hysteria.previous" had_old=0 was_active=0
  [[ ! -L "$cfg" ]] || die "refusing to overwrite symlink $cfg"
  [[ ! -f "$cfg" ]] || { cp -a "$cfg" "$previous"; had_old=1; }
  if systemctl is-active --quiet hysteria-server; then was_active=1; fi
  render_hysteria_config > "$WORK_DIR/config.yaml"
  install -m 640 -o root -g hysteria "$WORK_DIR/config.yaml" "$candidate"
  # Hysteria has no 'check' subcommand. Validate using the real server on an
  # ephemeral UDP port as its service user, before replacing the live config.
  python3 - "$candidate" "$WORK_DIR/probe.json" <<'PY_PROBE'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
c['listen'] = '127.0.0.1:0'
with open(sys.argv[2], 'w') as f:
    json.dump(c, f)
PY_PROBE
  install -m 640 -o root -g hysteria "$WORK_DIR/probe.json" /etc/hysteria/.bootstrap-probe.yaml
  local rc=0
  timeout 3 runuser -u hysteria -- hysteria server --config /etc/hysteria/.bootstrap-probe.yaml > "$WORK_DIR/probe.log" 2>&1 || rc=$?
  rm -f /etc/hysteria/.bootstrap-probe.yaml
  if [[ "$rc" != 124 ]] || ! grep -q 'server up and running' "$WORK_DIR/probe.log"; then
    rm -f "$candidate"
    die "Hysteria rejected the candidate configuration; existing config preserved"
  fi
  mv -f "$candidate" "$cfg"
  local ok=0 i
  if systemctl restart hysteria-server; then
    for ((i=0; i<15; i++)); do
      if systemctl is-active --quiet hysteria-server && udp_owned_by_hysteria; then ok=1; break; fi
      sleep 1
    done
  fi
  if (( ok )); then
    systemctl enable hysteria-server >/dev/null
    return
  fi
  if (( had_old )); then cp -a "$previous" "$cfg"; else rm -f "$cfg"; fi
  systemctl stop hysteria-server || true
  if (( was_active )); then systemctl start hysteria-server || true; fi
  die "Hysteria startup failed; previous config restored (see journalctl -u hysteria-server)"
}

ensure_hysteria_restart_policy() {
  install -d -m 755 /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/bootstrap.conf <<'UNIT'
[Service]
Restart=on-failure
RestartSec=5
UNIT
  systemctl daemon-reload
}

verify_services() {
  nginx -t
  systemctl is-active --quiet nginx
  systemctl is-active --quiet hysteria-server
  udp_owned_by_hysteria || die "expected UDP socket is not owned by hysteria-server"
  runuser -u hysteria -- test -r "$HYSTERIA_CERT_PATH"
  runuser -u hysteria -- test -r "$HYSTERIA_KEY_PATH"
  curl --noproxy '*' --resolve "$DOMAIN:443:127.0.0.1" -fsS --max-time 10 "https://$DOMAIN/" >/dev/null
  log "local HTTPS, certificate access, Hysteria service and UDP owner verified"
}
print_summary() {
  printf '\nWebsite: https://%s\nHysteria 2: %s:%s/udp\nTLS SNI: %s\n' "$DOMAIN" "$DOMAIN" "$PORT" "$DOMAIN"
  printf 'Config: /etc/hysteria/config.yaml (root:hysteria, 640)\nBackup: %s\n' "$BACKUP_DIR"
  if (( SHOW_PASSWORD )); then printf 'Password: %s\n' "$PASSWORD"; else printf 'Password: hidden (existing password preserved; --show-password to display)\n'; fi
  printf 'Check external connectivity from your client; provider firewall must allow TCP 80/443 and UDP %s.\n' "$PORT"
}

# ---------- main ----------
main() {
  parse_args "$@"
  validate_inputs
  require_environment
  backup_existing_configs
  detect_ipv6
  install_base_packages
  load_password
  # One instance only: do not silently move an existing managed service to another domain.
  if [[ -f /etc/hysteria/bootstrap-domain && "$(cat /etc/hysteria/bootstrap-domain)" != "$DOMAIN" ]]; then
    die "this service is managed for another domain; migrate it explicitly"
  fi
  preflight_dns
  configure_firewall
  validate_existing_lineage
  write_status_page
  if certificate_usable 0; then write_nginx_site 1; else write_nginx_site 0; fi
  issue_certificate
  write_nginx_site 1
  install_hysteria
  begin_hysteria_transaction
  setup_hysteria_certs
  ensure_hysteria_restart_policy
  write_hysteria_config
  verify_services
  printf '%s\n' "$DOMAIN" > /etc/hysteria/bootstrap-domain
  ROLLBACK_HYSTERIA=0
  print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
