#!/usr/bin/env bash
# DESTRUCTIVE TEST: use only on a disposable GitHub-hosted VM.
set -Eeuo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
  echo 'This integration test is restricted to disposable GitHub-hosted runners.' >&2; exit 1;
}
(( EUID == 0 )) || { echo 'Run with sudo -E'; exit 1; }
repo="$(cd "$(dirname "$0")/.." && pwd)"
domain=bootstrap.example.test
trap 'journalctl -u nginx -u hysteria-server -n 60 --no-pager || true' ERR
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ca-certificates curl openssl python3 python3-yaml acl iproute2 openssh-server
# Install the actual Hysteria binary and official systemd unit, pinned for CI.
curl -fsSL --retry 3 https://github.com/apernet/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64 -o /tmp/hysteria
curl -fsSL --retry 3 https://raw.githubusercontent.com/apernet/hysteria/app/v2.13.0/scripts/install_server.sh -o /tmp/install-hysteria.sh
bash /tmp/install-hysteria.sh --local /tmp/hysteria
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout /tmp/bootstrap-ca.key -out /tmp/bootstrap-ca.crt -subj /CN=Bootstrap-Test-CA >/dev/null 2>&1
cp /tmp/bootstrap-ca.crt /usr/local/share/ca-certificates/bootstrap-test.crt
update-ca-certificates >/dev/null
mkdir -p /tmp/bootstrap-fixtures
install -m 755 "$repo/tests/fixtures/certbot" /tmp/bootstrap-fixtures/certbot
cat > /tmp/bootstrap-fixtures/curl <<'CURL'
#!/usr/bin/env bash
case "$*" in
  *https://api.ipify.org*|*https://ifconfig.me/ip*) printf '203.0.113.10' ;;
  *) exec /usr/bin/curl "$@" ;;
esac
CURL
cat > /tmp/bootstrap-fixtures/dig <<'DIG'
#!/usr/bin/env bash
case " $* " in *' AAAA '*) ;; *' A '*) echo 203.0.113.10 ;; esac
DIG
chmod 755 /tmp/bootstrap-fixtures/{curl,dig}
export PATH="/tmp/bootstrap-fixtures:$PATH"
# Induce the reported package failure on IPv4-only runners, before bootstrap.
if [[ "${TEST_IPV6:-0}" == 0 ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
else
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
fi
apt-get install -y nginx || true
if [[ "${TEST_IPV6:-0}" == 0 ]]; then
  systemctl stop nginx || true
  printf '\nserver {\n listen [::]:18080;\n}\n' >> /etc/nginx/sites-available/default
  if nginx -t; then echo 'Expected IPv6 failure not reproduced' >&2; exit 1; fi
  # Exercise dpkg --configure -a with nginx explicitly awaiting configuration.
  dpkg --unpack /var/cache/apt/archives/nginx_*.deb 2>/dev/null || {
    (cd /tmp && apt-get download nginx)
    dpkg --unpack /tmp/nginx_*.deb
  }
  if dpkg --configure nginx; then echo 'Expected interrupted nginx configuration' >&2; exit 1; fi
fi
printf '%s\n' 'true: # "quotes" & unicode-кириллица' > /tmp/bootstrap.password
chmod 600 /tmp/bootstrap.password
args=(--domain "$domain" --email admin@example.test --port 443)
bash "$repo/setup-hysteria.sh" "${args[@]}" --password-file /tmp/bootstrap.password > /tmp/first.log 2>&1 || { cat /tmp/first.log; exit 1; }
cat /tmp/first.log
[[ -z "$(dpkg --audit)" ]]
[[ ! -e /usr/sbin/policy-rc.d.hysteria-backup ]]
if [[ "${TEST_IPV6:-0}" == 0 ]]; then
  if grep -E '^ *listen \[::\]' "/etc/nginx/sites-available/$domain"; then exit 1; fi
else
  grep -F 'listen [::]:80;' "/etc/nginx/sites-available/$domain"
fi
[[ "$(stat -c %a /etc/hysteria/config.yaml)" == 640 ]]
cp /etc/hysteria/config.yaml /tmp/first-config
# Same command with no password must reuse it, issue no cert, preserve HTTPS.
cat "$repo/setup-hysteria.sh" | bash -s -- "${args[@]}" > /tmp/repeat.log 2>&1 || { cat /tmp/repeat.log; exit 1; }
cmp /etc/hysteria/config.yaml /tmp/first-config
[[ "$(wc -l < /tmp/certbot-calls)" == 1 ]]
if grep -F 'unicode-кириллица' /tmp/first.log /tmp/repeat.log; then exit 1; fi
# Validate an actual Hysteria client authentication and proxy request.
python3 - <<'PY_CLIENT'
import json
from pathlib import Path
c=json.loads(Path('/etc/hysteria/config.yaml').read_text())
Path('/tmp/client.yaml').write_text(json.dumps({'server':'127.0.0.1:443', 'auth':c['auth']['password'], 'tls':{'sni':'bootstrap.example.test','ca':'/tmp/bootstrap-ca.crt'}, 'socks5':{'listen':'127.0.0.1:1080'}}))
PY_CLIENT
hysteria client --config /tmp/client.yaml >/tmp/client.log 2>&1 &
client_pid=$!
for i in {1..20}; do
  if /usr/bin/curl --noproxy '' --socks5-hostname 127.0.0.1:1080 -fsS --max-time 3 http://127.0.0.1/ >/dev/null; then break; fi
  if (( i == 20 )); then cat /tmp/client.log; exit 1; fi
  sleep 1
done
kill "$client_pid"
# Renewal copies a new pair, regrants ACL after mode changes and reloads nginx.
bash "$repo/setup-hysteria.sh" "${args[@]}" --force-renew --cert-mode acl > /tmp/acl.log 2>&1 || { cat /tmp/acl.log; exit 1; }
grep -q -- '--force-renewal' /tmp/certbot-calls
RENEWED_LINEAGE="/etc/letsencrypt/live/$domain" /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh
runuser -u hysteria -- test -r "/etc/letsencrypt/live/$domain/privkey.pem"
bash "$repo/setup-hysteria.sh" "${args[@]}" --cert-mode copy >/tmp/copy.log 2>&1 || { cat /tmp/copy.log; exit 1; }
certbot certonly --webroot-path "/var/www/$domain" --cert-name "$domain" -d "$domain"
RENEWED_LINEAGE="/etc/letsencrypt/live/$domain" /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh
cmp "/etc/letsencrypt/live/$domain/privkey.pem" /etc/hysteria/certs/current/privkey.pem
# An unrelated lineage must not mutate the active cert snapshot.
before="$(readlink /etc/hysteria/certs/current)"
RENEWED_LINEAGE=/etc/letsencrypt/live/unrelated.test /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh
[[ "$before" == "$(readlink /etc/hysteria/certs/current)" ]]
# Changing webroot without renewal must fail before modifying nginx.
cp "/etc/nginx/sites-available/$domain" /tmp/site-before
if bash "$repo/setup-hysteria.sh" "${args[@]}" --webroot /var/www/changed >/tmp/changed.log 2>&1; then exit 1; fi
cmp "/etc/nginx/sites-available/$domain" /tmp/site-before
# Force startup failure with a UDP listener; verify config + hook rollback.
cp /etc/hysteria/config.yaml /tmp/before-config
cp /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh /tmp/before-hook
python3 -c 'import socket,time;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("0.0.0.0",24443));time.sleep(120)' &
blocker_pid=$!
sleep 1
if bash "$repo/setup-hysteria.sh" --domain "$domain" --email admin@example.test --port 24443 --cert-mode acl >/tmp/rollback.log 2>&1; then kill "$blocker_pid"; exit 1; fi
kill "$blocker_pid"
cmp /etc/hysteria/config.yaml /tmp/before-config
cmp /etc/letsencrypt/renewal-hooks/deploy/hysteria-bootstrap.sh /tmp/before-hook
systemctl is-active --quiet hysteria-server
ss -H -lunp 'sport = :443' | grep hysteria
# Exercise explicit UFW activation with a nonstandard SSH port on a disposable VM.
SSH_CONNECTION='192.0.2.1 50000 203.0.113.10 2222' bash "$repo/setup-hysteria.sh" "${args[@]}" --ufw enable >/tmp/ufw.log 2>&1 || { cat /tmp/ufw.log; exit 1; }
ufw status | grep '2222/tcp'
ufw status | grep '443/udp'
ufw disable
printf '\nIntegration passed: install, dpkg recovery, rerun, client handshake, renewal, ACL/copy, rollback, UFW.\n'
