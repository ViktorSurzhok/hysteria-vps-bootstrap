"""Local regression tests. Never run the installer or modify the host."""
import json
import os
from pathlib import Path
import subprocess
import shlex
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'setup-hysteria.sh'
FUNCTIONS = "source " + shlex.quote(str(SCRIPT))


def run_bash(code, **env):
    return subprocess.run(['bash', '-c', FUNCTIONS + '\n' + code],
                          env={**os.environ, **env}, text=True, capture_output=True)


class BootstrapTests(unittest.TestCase):
    def test_invalid_webroot_rejected(self):
        r = run_bash('DOMAIN=node.example.com; EMAIL=a@example.com; PASSWORD=test; '
                     'WEBROOT="/tmp/site;include /etc/passwd"; validate_inputs')
        self.assertNotEqual(r.returncode, 0, r.stdout)

    def test_decimal_port_with_leading_zero(self):
        r = run_bash('DOMAIN=node.example.com; EMAIL=a@example.com; PASSWORD=test; '
                     'PORT=08443; validate_inputs; printf "port=%s" "$PORT"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('port=8443', r.stdout)

    def test_inactive_firewall_is_not_enabled(self):
        r = run_bash('ufw() { printf "ufw %s\\n" "$*" >&2; '
                     'if [[ "$1" == status ]]; then echo "Status: inactive"; fi; }; '
                     'configure_firewall')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('--force enable', r.stderr)
        self.assertNotIn('allow ', r.stderr)

    def test_repair_ipv6_preserves_other_directives(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'default'
            p.write_text('server {\n listen 80 default_server;\n listen [::]:80 default_server;\n # listen [::]:443 ssl;\n server_name _;\n}\n')
            r = run_bash('repair_ipv6_file "$FIXTURE"', FIXTURE=str(p))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(p.read_text(), 'server {\n listen 80 default_server;\n # listen [::]:443 ssl;\n server_name _;\n}\n')

    def test_config_password_roundtrip(self):
        password = 'true: # \\" & <test> 😀'
        r = run_bash('PORT=443; IPV6_AVAILABLE=0; PASSWORD="$TEST_PASSWORD"; '
                     'WEBROOT=/var/www/test; HYSTERIA_CERT_PATH=/tmp/fullchain.pem; HYSTERIA_KEY_PATH=/tmp/key.pem; '
                     'render_hysteria_config', TEST_PASSWORD=password)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)  # JSON is a YAML 1.2 subset accepted by Hysteria.
        self.assertEqual(data['auth']['password'], password)
        self.assertEqual(data['listen'], '0.0.0.0:443')
        self.assertEqual(data['masquerade'], {'type': 'file', 'file': {'dir': '/var/www/test'}})

    def test_missing_flag_value_is_clear(self):
        r = run_bash('parse_args --domain')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('missing value for --domain', r.stderr)

    def test_invalid_ports(self):
        for port in ('0', '65536', '999999999999999999', '-1', 'abc'):
            with self.subTest(port=port):
                r = run_bash('DOMAIN=node.example.com; EMAIL=a@example.com; PORT="$TEST_PORT"; validate_inputs', TEST_PORT=port)
                self.assertNotEqual(r.returncode, 0)

    def test_nginx_listeners_follow_ipv6_detection(self):
        for ipv6 in ('0', '1'):
            with self.subTest(ipv6=ipv6):
                r = run_bash('DOMAIN=node.example.com; WEBROOT=/var/www/node; IPV6_AVAILABLE="$TEST_IPV6"; render_nginx_site 1', TEST_IPV6=ipv6)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual('listen [::]:80;' in r.stdout, ipv6 == '1')
                self.assertEqual('listen [::]:443 ssl http2;' in r.stdout, ipv6 == '1')
                self.assertIn('location ^~ /.well-known/acme-challenge/', r.stdout)
                self.assertIn('location / { return 301', r.stdout)

    def test_firewall_skip_does_not_invoke_ufw(self):
        r = run_bash('ufw() { exit 91; }; UFW_MODE=skip; configure_firewall')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_active_firewall_keeps_ssh_rules(self):
        r = run_bash('ufw() { printf "ufw %s\\n" "$*" >&2; [[ "$1" != status ]] || echo "Status: active"; }; configure_firewall')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('allow 8443/udp', r.stderr)
        self.assertNotIn('22/tcp', r.stderr)
        self.assertNotIn('enable', r.stderr)
        self.assertNotIn('reset', r.stderr)

    def test_ssh_discovery_uses_session_config_and_socket(self):
        r = run_bash('''sshd() { printf "port 2022\\n"; }; ss() { echo 'LISTEN 0 128 0.0.0.0:3022 0.0.0.0:* users:(("sshd",pid=42,fd=3))'; };
            systemctl() { if [[ "$1" == show ]]; then echo '[::]:4022 (Stream)'; fi; };
            SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 2222'; SSH_PORTS=(5022);
            discover_ssh_ports; printf '%s\\n' "${SSH_PORTS[@]}"''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(set(r.stdout.split()), {'2022','2222','3022','4022','5022'})

    def test_html_escape(self):
        r = run_bash("html_escape '<test>&' ")
        self.assertEqual(r.stdout, '&lt;test&gt;&amp;')

    def test_stdin_entrypoint(self):
        r = subprocess.run(['bash', '-s', '--', '--version'], input=SCRIPT.read_text(), text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('hysteria-vps-bootstrap 1.1.0', r.stdout)

    def test_malformed_existing_yaml_never_echoes_password(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'config.yaml'
            p.write_text('auth: [SUPER_SECRET: broken: yaml]')
            r = run_bash('read_existing_password "$FIXTURE"', FIXTURE=str(p))
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('SUPER_SECRET', r.stdout + r.stderr)
            self.assertIn('provide --password-file', r.stderr)


if __name__ == '__main__':
    unittest.main()
