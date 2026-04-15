# Hysteria VPS Bootstrap

Production-grade bootstrap script for **Hysteria 2 + Nginx + Let's Encrypt + status page** on a clean Debian/Ubuntu VPS.

One shell file, idempotent re-runs, hardened TLS, DNS preflight, automatic backups of existing configs, and two supported ways of delivering TLS material to the `hysteria` user.

Source and issues: [github.com/ViktorSurzhok/hysteria-vps-bootstrap](https://github.com/ViktorSurzhok/hysteria-vps-bootstrap).

---

## Table of contents

- [What the script does](#what-the-script-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [CLI reference](#cli-reference)
- [Secrets handling](#secrets-handling)
- [Certificate delivery modes](#certificate-delivery-modes)
- [Idempotency and re-runs](#idempotency-and-re-runs)
- [What gets hardened](#what-gets-hardened)
- [Backups and recovery](#backups-and-recovery)
- [Verification](#verification)
- [Client configuration (Surge / others)](#client-configuration)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Uninstall](#uninstall)
- [License](#license)

---

## What the script does

1. Installs base packages: `nginx`, `certbot`, `python3-certbot-nginx`, `ufw`, `dnsutils`, `openssl`, `jq`, plus `acl` when `--cert-mode acl`.
2. **DNS preflight.** Resolves all A records for the domain via `1.1.1.1`, fetches the VPS public IPv4, and fails fast if they do not match — so you never hit a Let's Encrypt rate limit because of a misconfigured DNS record.
3. **Backs up** existing `/etc/nginx`, `/etc/hysteria`, and Let's Encrypt renewal metadata to `/root/hysteria-vps-bootstrap-backup-<timestamp>/` before touching anything.
4. Configures **UFW** (`22/tcp`, `80/tcp`, `443/tcp`, `<port>/udp`), verifies the SSH rule is queued before enabling the firewall, and refuses to enable it otherwise.
5. Writes an HTTP vhost, brings up a minimal status page, and runs `nginx -t` before every reload.
6. Issues a Let's Encrypt certificate via `certbot --nginx`. **Idempotent:** if a valid cert with more than 30 days of life already exists, issuance is skipped (unless `--force-renew` is passed).
7. Replaces the vhost with a **hardened HTTPS config**: TLS 1.2 + 1.3, modern AEAD ciphers, OCSP stapling, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`.
8. Installs **Hysteria 2** via the upstream installer (fetched to a temp file, sanity-checked to be a shell script before exec).
9. Delivers TLS material to the `hysteria` user using either the **copy** or **ACL** mode (see below), and in both cases installs a certbot deploy-hook so renewals stay in sync.
10. Writes `/etc/hysteria/config.yaml` with `mode 640 root:hysteria`, using `umask 077` so the file never exists world-readable.
11. Installs a systemd drop-in: `Restart=always`, `RestartSec=5`.
12. **Verifies** nginx is active, hysteria-server is active, the UDP port is actually listening, the `hysteria` user can read the TLS files, and that `https://<domain>` responds.
13. Prints a summary with the connection parameters and a masked password.

All of this happens from a single `main()` that reads as a pipeline — if you want to remove a step, delete one line.

---

## Requirements

Before running:

- A **clean Debian/Ubuntu** VPS with `apt-get`.
- **root** (or `sudo`).
- **DNS A record** for your domain pointing to the VPS public IPv4. The script will bail out early if this is wrong — don't rely on "propagation will happen later".
- A **real email on your own domain** for `--email`. This is where Let's Encrypt will notify you about certificate expiry and CAA issues. Example: for `--domain node.example.com`, use `admin@example.com`.
- Open in your cloud firewall:
  - `22/tcp`
  - `80/tcp`
  - `443/tcp`
  - your chosen UDP port (default `8443/udp`)

---

## Quick start

```bash
# Preferred: password from a file, never on the command line
echo 'StrongPasswordHere' > /root/.hysteria.pw
chmod 600 /root/.hysteria.pw

sudo bash setup-hysteria.sh \
  --domain static.example.com \
  --email admin@example.com \
  --password-file /root/.hysteria.pw \
  --port 8443 \
  --cert-mode copy \
  --site-title "Инфраструктурный узел активен."
```

One-liner from GitHub (you still need to ship your own password file — we do not accept secrets on stdin piped from `curl` to avoid logging them in shell history):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ViktorSurzhok/hysteria-vps-bootstrap/main/setup-hysteria.sh) \
  --domain static.example.com \
  --email admin@example.com \
  --password-file /root/.hysteria.pw \
  --port 8443
```

---

## CLI reference

| Flag | Required | Description |
|---|---|---|
| `--domain <fqdn>` | yes | Domain for the site, TLS SNI, and ACME challenge. Must already resolve to this VPS. |
| `--email <addr>` | yes | Contact email for Let's Encrypt. Use your own domain. |
| `--password <pw>` | one of | Hysteria 2 auth password. **Visible in `ps` and shell history** — prefer `--password-file`. |
| `--password-file <path>` | one of | Read password from the first line of a file. `chmod 600` the file before running. |
| `--port <udp>` | no | UDP port for Hysteria (default `8443`). Range 1–65535. |
| `--webroot <path>` | no | Site root (default `/var/www/<domain>`). |
| `--site-title <text>` | no | Subtitle on the status page. **HTML-escaped automatically** — you can put quotes and tags in there safely. |
| `--cert-mode <copy\|acl>` | no | How Hysteria reads LE certs. Default: `copy`. See [Certificate delivery modes](#certificate-delivery-modes). |
| `--force-renew` | no | Force certbot to reissue even if the current cert is valid >30 days. |
| `--yes`, `-y` | no | Assume yes on non-fatal confirmations. |
| `-h`, `--help` | no | Show usage. |
| `-V`, `--version` | no | Print script version. |

If neither `--password` nor `--password-file` is supplied and the script is running interactively (`stdin` is a TTY), it will prompt for the password with echo disabled.

---

## Secrets handling

- **Never pass `--password` in a shared shell.** It will be visible in `ps auxf`, in your history file, and likely in any terminal screencast. Use `--password-file` or let the interactive prompt ask for it.
- The password is **masked** in all log output (`ab***yz`).
- `config.yaml` is written with `umask 077`, then `chown root:hysteria` and `chmod 640` — it is never world-readable, even for a fraction of a second.
- The script **does not** cat the config to stdout. Previous versions did; the current version does not, so journald will not record the plaintext password during normal runs.
- The password is **not** logged in plaintext anywhere, and it does not end up in the nginx status page or HTML.

---

## Certificate delivery modes

Hysteria runs as an unprivileged `hysteria` user and therefore cannot read `/etc/letsencrypt/archive/<domain>/privkey*.pem` with default permissions. There are two well-known ways to fix this, and this script supports both.

### `--cert-mode copy` (default)

What happens:
- `fullchain.pem` and `privkey.pem` are copied into `/etc/hysteria/certs/`, owned by `hysteria:hysteria`, mode `640`.
- A certbot **deploy-hook** is installed at `/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync-<domain>.sh`. After every successful renewal for this lineage, the hook re-copies the certs and reloads `hysteria-server`.
- The hook filters on `$RENEWED_LINEAGE` so it only runs for your domain — not for unrelated certificates you may issue later.

**Why it is the default:** it works on any filesystem, does not depend on ACL support, is trivial to reason about, and is easy to recover manually if something breaks.

**Trade-off:** there are now two copies of the private key on disk (LE's `archive/` and `/etc/hysteria/certs/`), and if the deploy-hook ever fails silently, Hysteria will serve a stale certificate.

### `--cert-mode acl`

What happens:
- The script verifies the target filesystem actually supports POSIX ACLs (it writes a probe file and runs `setfacl` against it; if that fails, it **falls back to copy mode automatically**, with a warning).
- Traverse bit (`x`, no `r`) for the `hysteria` user is set on every directory in the chain: `/etc/letsencrypt/live`, `/etc/letsencrypt/archive`, and the per-domain subdirectories. `x` without `r` means "enter, but cannot list" — Hysteria sees only the files it is explicitly granted.
- Read bit (`r`) is granted on every existing versioned file inside `/etc/letsencrypt/archive/<domain>/` (`privkey*.pem`, `fullchain*.pem`, `chain*.pem`, `cert*.pem`).
- A **default ACL** is set on `/etc/letsencrypt/archive/<domain>/`, so files created by future certbot renewals automatically inherit the ACL. Without this, certbot would write `privkey2.pem` with no ACL and Hysteria would silently start failing after ~60 days.
- The script then **verifies as the `hysteria` user** (`sudo -u hysteria test -r ...`) that the `live/<domain>/fullchain.pem` and `privkey.pem` symlinks are actually readable. If verification fails for any reason, it falls back to copy mode.
- A minimal deploy-hook is installed that only reloads `hysteria-server` (no file copying is needed in ACL mode).

**Why it is not the default:** it is stricter about the environment. If you are on an exotic filesystem, inside an unprivileged container, or on a SELinux-enforcing system, ACLs can silently stop applying after a package update or a `restorecon` run. Copy mode has none of those failure modes.

**When to choose ACL:** if you want a single source of truth for the private key and you are on a standard ext4/xfs/btrfs Debian/Ubuntu VPS.

**Fallbacks.** ACL mode falls back to copy mode in any of these cases, all with a `[WARN]` log line:
- `setfacl` binary missing after install.
- Probe file cannot be created under `/etc/letsencrypt`.
- Probe `setfacl` call fails (filesystem does not support ACLs).
- Post-setup read verification fails as the `hysteria` user.

---

## Idempotency and re-runs

You can re-run this script on the same host — that is a supported workflow.

- `certbot` is called with `--keep-until-expiring`, and the script short-circuits entirely if a valid cert with more than 30 days of life exists. Use `--force-renew` to override this.
- `ufw` rules are queued idempotently; re-running does not duplicate them.
- Nginx vhost files are overwritten intentionally — that is the whole point. The previous content is in the timestamped backup directory.
- The Hysteria installer self-detects an existing install and skips its heavy lifting; this script additionally skips the install step entirely if the `hysteria` binary is already on `$PATH`.
- The systemd drop-in is overwritten on every run.
- ACL commands are additive and idempotent; repeated runs do not accumulate garbage.

The one thing that is **not** idempotent across re-runs is the backup directory: a new one is created every run, with a timestamp suffix. This is intentional — each run produces an independent recoverable checkpoint.

---

## What gets hardened

### Nginx TLS

- `ssl_protocols TLSv1.2 TLSv1.3` — no SSLv3, no TLS 1.0/1.1.
- AEAD-only cipher suite (AES-GCM + CHACHA20-POLY1305), `ssl_prefer_server_ciphers off` (client chooses, which is the modern recommendation).
- `ssl_session_tickets off` — no session-ticket-key rotation burden, forward secrecy is preserved.
- OCSP stapling (`ssl_stapling on`, `ssl_stapling_verify on`), with `resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off`.
- `Strict-Transport-Security: max-age=63072000; includeSubDomains` (2 years).
- `X-Content-Type-Options: nosniff`.
- `X-Frame-Options: DENY`.
- `Referrer-Policy: no-referrer`.
- `Permissions-Policy: interest-cohort=()`.

### Script

- `set -Eeuo pipefail`.
- `trap ERR` that prints the failing line and the backup directory so you can roll back.
- All user-facing inputs are validated (FQDN regex, email regex, numeric port range, cert-mode enum).
- `--site-title` and `--domain` are HTML-escaped before being interpolated into the status page — no XSS.
- `--password` is masked in logs, prompted with `read -s` when interactive, and written to a `mode 640 root:hysteria` file under `umask 077`.
- The upstream Hysteria installer is fetched to a temp file and checked to start with `#!` before being executed.
- UFW verifies the SSH rule is queued before enabling the firewall.

---

## Backups and recovery

Every run creates `/root/hysteria-vps-bootstrap-backup-<YYYYMMDD-HHMMSS>/` containing:

- `nginx/` — full copy of `/etc/nginx` as it was before the run.
- `hysteria/` — full copy of `/etc/hysteria` (if it existed).
- `letsencrypt-meta/` — `renewal/` and `renewal-hooks/` from `/etc/letsencrypt`. Private keys themselves are **not** copied (they are never duplicated needlessly).

To roll back the nginx changes:

```bash
sudo cp -a /root/hysteria-vps-bootstrap-backup-<ts>/nginx/. /etc/nginx/
sudo nginx -t && sudo systemctl reload nginx
```

To roll back the hysteria config:

```bash
sudo cp -a /root/hysteria-vps-bootstrap-backup-<ts>/hysteria/. /etc/hysteria/
sudo systemctl restart hysteria-server
```

---

## Verification

The script's own `verify_services` step checks all of these automatically. If you want to run them by hand:

```bash
# hysteria-server
systemctl status hysteria-server --no-pager -l
journalctl -u hysteria-server -n 50 --no-pager
ss -ulnp | grep :8443

# nginx + HTTPS
systemctl status nginx --no-pager -l
curl -I https://your-domain.com

# TLS handshake details (from outside)
openssl s_client -connect your-domain.com:443 -servername your-domain.com -tls1_3 </dev/null 2>/dev/null | openssl x509 -noout -dates -issuer -subject

# cert reachable by hysteria user (useful for debugging ACL mode)
sudo -u hysteria test -r /etc/letsencrypt/live/your-domain.com/privkey.pem && echo OK || echo FAIL
```

---

## Client configuration

Tested with Surge; the same parameters apply to any Hysteria 2 client.

- **Protocol:** Hysteria 2
- **Server Address:** VPS IP (often more reliable than the domain, especially on networks that mangle DNS)
- **Port:** whatever you passed to `--port`
- **Password:** the one from your `--password-file`
- **Custom TLS SNI:** your domain
- **IP Version:** IPv4 Only, unless you know you need v6

---

## Troubleshooting

**Certbot failed with "Invalid response from …".** Your DNS A record does not point to this VPS, or port 80 is blocked at the cloud firewall level. The DNS preflight should have caught this — if you bypassed it or it passed but the Let's Encrypt validator still fails, check the cloud firewall.

**`hysteria-server` is active but nothing connects.** Check `ss -ulnp | grep :<port>`. If it is missing, the service is running but not binding — usually a TLS file permission problem. Re-run with `--cert-mode copy` to sidestep ACL-related issues, or run `sudo -u hysteria test -r /etc/letsencrypt/live/<domain>/privkey.pem` to see the actual permission error.

**HTTPS works in the browser but `curl -I https://<domain>` returns a connection error on the VPS itself.** Almost always IPv6: the VPS has an AAAA record pointing somewhere else, and nginx is binding only v4. Either add `listen [::]:443 ssl;` (already in the hardened vhost) and fix DNS, or disable v6 on the host.

**ACL mode silently stopped working after ~60 days.** Certbot renewed and created `privkey2.pem` in `archive/` without inheriting the ACL. This should not happen because the script sets a default ACL on the archive directory — but if it does, check `getfacl /etc/letsencrypt/archive/<domain>/` and verify the `default:user:hysteria:r--` entry is still present. If it was dropped (package upgrade, manual `setfacl --remove-all`), re-run the bootstrap or re-apply the ACLs manually.

**"Let's Encrypt rate limit exceeded".** You ran the script too many times without `--force-renew` protection, on older versions of this script. The current version is idempotent and will not re-issue a valid certificate. Wait out the rate limit, then re-run — it will skip issuance and only fix the downstream state.

**`ufw` blocked my SSH.** The script queues the SSH rule and refuses to enable the firewall if the rule is missing, so this should not happen. If it does anyway (for example, a pre-existing deny rule matched first), fall back to your cloud provider's console to re-enable SSH.

---

## Security notes

- This script is designed for **you owning the VPS**. It is not a security appliance for hostile tenants. In particular, anyone with `root` on the box can read `/etc/hysteria/config.yaml`.
- The Hysteria password is effectively the only auth factor. Pick one from a password manager, ship it via `--password-file`, and rotate it if it leaks.
- Let's Encrypt private keys live in `/etc/letsencrypt/archive/<domain>/`. In `copy` mode, a second copy lives in `/etc/hysteria/certs/`. In `acl` mode, only the original copy exists.
- No fail2ban, no rate limiting on Nginx, no IDS. Add those separately if your threat model needs them — they are intentionally out of scope for a bootstrap script.
- SELinux is not handled. If you are on a distro that ships SELinux enforcing, you are on your own — submit an issue.

---

## Uninstall

There is no one-shot uninstaller (scope decision). To undo what the script did:

```bash
# Stop and disable hysteria
sudo systemctl disable --now hysteria-server
sudo rm -f /etc/systemd/system/hysteria-server.service.d/override.conf
sudo systemctl daemon-reload

# Remove hysteria binary (installer-provided)
sudo bash -c 'command -v hysteria && hysteria --help >/dev/null'  # check what is installed
sudo rm -f /usr/local/bin/hysteria
sudo rm -rf /etc/hysteria
sudo userdel hysteria 2>/dev/null || true

# Remove nginx vhost
sudo rm -f /etc/nginx/sites-enabled/<domain> /etc/nginx/sites-available/<domain>
sudo systemctl reload nginx

# Remove certbot deploy-hook
sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-*-<domain>.sh

# Optional: revoke the certificate
sudo certbot revoke --cert-name <domain>
sudo certbot delete --cert-name <domain>

# Optional: close the UDP port
sudo ufw delete allow <port>/udp
```

Leave `nginx`, `certbot`, and `ufw` installed unless you are sure you do not need them.

---

## License

See [LICENSE](LICENSE). Use at your own risk; verify the configuration against your own security policy before running in production.

## GitHub About

Copy-paste descriptions for the repository About field live in [GITHUB_REPO_META.md](GITHUB_REPO_META.md).
