# Hysteria VPS Bootstrap

Прод-скрипт для развёртывания **Hysteria 2 + Nginx + Let's Encrypt + статусной страницы** на чистом Debian/Ubuntu VPS.

Один shell-файл, идемпотентные повторные запуски, хардененный TLS, DNS-preflight, автоматический бэкап существующих конфигов и два способа доставки TLS-материала до пользователя `hysteria`.

Исходники и issues: [github.com/ViktorSurzhok/hysteria-vps-bootstrap](https://github.com/ViktorSurzhok/hysteria-vps-bootstrap).

---

## Оглавление

- [Что делает скрипт](#что-делает-скрипт)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Справочник по CLI](#справочник-по-cli)
- [Работа с секретами](#работа-с-секретами)
- [Режимы доставки сертификатов](#режимы-доставки-сертификатов)
- [Идемпотентность и повторные запуски](#идемпотентность-и-повторные-запуски)
- [Что захарденено](#что-захарденено)
- [Бэкапы и восстановление](#бэкапы-и-восстановление)
- [Проверка](#проверка)
- [Настройка клиента (Surge и другие)](#настройка-клиента)
- [Диагностика проблем](#диагностика-проблем)
- [Заметки по безопасности](#заметки-по-безопасности)
- [Удаление](#удаление)
- [Лицензия](#лицензия)

---

## Что делает скрипт

1. Ставит базовые пакеты: `nginx`, `certbot`, `python3-certbot-nginx`, `ufw`, `dnsutils`, `openssl`, `jq`, плюс `acl` если выбран `--cert-mode acl`.
2. **DNS-preflight.** Резолвит все A-записи домена через `1.1.1.1`, получает публичный IPv4 VPS и падает рано, если они не совпадают — чтобы вы никогда не ловили rate-limit от Let's Encrypt из-за кривой DNS-записи.
3. **Бэкапит** существующие `/etc/nginx`, `/etc/hysteria` и метаданные renewal Let's Encrypt в `/root/hysteria-vps-bootstrap-backup-<timestamp>/` до того, как что-то трогает.
4. Настраивает **UFW** (`22/tcp`, `80/tcp`, `443/tcp`, `<порт>/udp`), проверяет что правило для SSH поставлено в очередь **до** включения firewall и отказывается включать его иначе.
5. Пишет HTTP vhost, поднимает минимальную статус-страницу и гоняет `nginx -t` перед каждым reload.
6. Выпускает сертификат Let's Encrypt через `certbot --nginx`. **Идемпотентно:** если валидный сертификат с запасом больше 30 дней уже есть — выпуск пропускается (кроме случая с `--force-renew`).
7. Заменяет vhost на **хардененный HTTPS-конфиг**: TLS 1.2 + 1.3, современные AEAD-cipher'ы, OCSP stapling, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`.
8. Ставит **Hysteria 2** через upstream-установщик (скачивает в temp-файл, проверяет что это shell-скрипт перед запуском).
9. Доставляет TLS-материал пользователю `hysteria` через режим **copy** или **acl** (см. ниже) и в обоих случаях ставит certbot deploy-hook, чтобы после renewal всё осталось синхронно.
10. Пишет `/etc/hysteria/config.yaml` в `mode 640 root:hysteria` под `umask 077` — файл никогда не существует world-readable даже на долю секунды.
11. Ставит systemd drop-in: `Restart=always`, `RestartSec=5`.
12. **Верифицирует:** nginx активен, hysteria-server активен, UDP-порт реально слушается, пользователь `hysteria` может прочитать TLS-файлы, `https://<domain>` отвечает.
13. Печатает summary с параметрами подключения и замаскированным паролем.

Всё это происходит из одного `main()`, который читается как pipeline — если какой-то шаг не нужен, удалите одну строку.

---

## Требования

До запуска:

- **Чистый Debian/Ubuntu** VPS с `apt-get`.
- **root** (или `sudo`).
- **DNS A-запись** для вашего домена, указывающая на публичный IPv4 VPS. Скрипт упадёт на preflight, если это не так — не надейтесь на «пропагация подъедет позже».
- **Реальный email на вашем домене** для `--email`. Туда Let's Encrypt шлёт уведомления об истечении сертификата и проблемах с CAA. Пример: для `--domain node.example.com` ставьте `admin@example.com`.
- В облачном firewall открыты:
  - `22/tcp`
  - `80/tcp`
  - `443/tcp`
  - выбранный UDP-порт (по умолчанию `8443/udp`)

---

## Быстрый старт

Самый простой вариант — не передавать пароль в аргументах вообще. Скрипт спросит его интерактивно (ввод без эха, в `ps` и history не попадёт):

```bash
sudo bash setup-hysteria.sh \
  --domain static.example.com \
  --email admin@example.com \
  --port 8443 \
  --site-title "Инфраструктурный узел активен."
# Hysteria password: ********
```

One-liner с GitHub — так же, без пароля в аргументах:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ViktorSurzhok/hysteria-vps-bootstrap/main/setup-hysteria.sh) \
  --domain static.example.com \
  --email admin@example.com \
  --port 8443
# Hysteria password: ********
```

Если вы автоматизируете установку (Ansible, CI, Terraform `remote-exec`) и интерактивный ввод невозможен — используйте `--password-file`:

```bash
install -m 600 /dev/null /root/.hysteria.pw
echo -n 'StrongPasswordHere' | sudo tee /root/.hysteria.pw >/dev/null

sudo bash setup-hysteria.sh \
  --domain static.example.com \
  --email admin@example.com \
  --password-file /root/.hysteria.pw \
  --port 8443

sudo shred -u /root/.hysteria.pw   # если не нужны повторные запуски
```

Флаг `--password <pw>` тоже существует, но **не рекомендуется**: пароль будет виден в `ps auxf` и попадёт в `~/.bash_history`.

---

## Справочник по CLI

| Флаг | Обяз. | Описание |
|---|---|---|
| `--domain <fqdn>` | да | Домен для сайта, TLS SNI и ACME-challenge. Должен уже резолвиться в этот VPS. |
| `--email <addr>` | да | Контактный email для Let's Encrypt. Используйте свой домен. |
| `--password <pw>` | один из | Пароль для Hysteria 2. **Виден в `ps` и shell history** — лучше используйте `--password-file`. |
| `--password-file <path>` | один из | Читает пароль из первой строки файла. Сделайте `chmod 600` перед запуском. |
| `--port <udp>` | нет | UDP-порт для Hysteria (по умолчанию `8443`). Диапазон 1–65535. |
| `--webroot <path>` | нет | Корень сайта (по умолчанию `/var/www/<domain>`). |
| `--site-title <text>` | нет | Подпись на статус-странице. **HTML-escape автоматически** — в тексте можно спокойно ставить кавычки и теги. |
| `--cert-mode <copy\|acl>` | нет | Как Hysteria читает LE-серты. По умолчанию: `copy`. См. [Режимы доставки сертификатов](#режимы-доставки-сертификатов). |
| `--force-renew` | нет | Заставить certbot перевыпустить серт, даже если текущий валиден >30 дней. |
| `--yes`, `-y` | нет | Считать ответ «да» на некритичные подтверждения. |
| `-h`, `--help` | нет | Показать usage. |
| `-V`, `--version` | нет | Вывести версию скрипта. |

Если не передан ни `--password`, ни `--password-file`, а скрипт запущен интерактивно (`stdin` — TTY), он спросит пароль с выключенным echo.

---

## Работа с секретами

- **Никогда не передавайте `--password` в общем shell.** Он будет виден в `ps auxf`, попадёт в history, скорее всего утечёт в записи терминала. Используйте `--password-file` или интерактивный ввод.
- Пароль **маскируется в логах по ходу установки** (`ab***yz`) — в том числе в `[INFO] config written: …`. Это касается всех промежуточных сообщений, которые могут уйти в `tee`, `script`, systemd journal и подобное.
- **В финальном блоке `==== RESULT ====` и в «Suggested Surge / client node» пароль печатается в plaintext** — сознательное решение ради удобства: запустил скрипт, сразу скопировал параметры в клиент. Это значит, что пароль попадёт в скроллбек терминала, скриншоты и запись SSH-сессии, если вы её ведёте. Очищайте за собой, не скриньте этот блок наружу.
- `config.yaml` пишется под `umask 077`, затем `chown root:hysteria` и `chmod 640` — файл никогда не бывает world-readable даже на мгновение.
- Скрипт **не** делает `cat` конфига в stdout. Старые версии это делали; текущая — нет, поэтому плейнтекст пароля не попадает в логи отдельной строкой.
- Пароль **не** оказывается на HTML-статус-странице и не уходит в certbot/nginx логи.

---

## Режимы доставки сертификатов

Hysteria работает от непривилегированного пользователя `hysteria` и поэтому не может читать `/etc/letsencrypt/archive/<domain>/privkey*.pem` с дефолтными правами. Есть два общепринятых способа это починить, и скрипт поддерживает оба.

### `--cert-mode copy` (по умолчанию)

Что происходит:
- `fullchain.pem` и `privkey.pem` копируются в `/etc/hysteria/certs/`, владелец `hysteria:hysteria`, режим `640`.
- Ставится certbot **deploy-hook** в `/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync-<domain>.sh`. После каждого успешного renewal для этого lineage hook пере-копирует серты и перезагружает `hysteria-server`.
- Hook фильтрует по `$RENEWED_LINEAGE` и отрабатывает только для вашего домена — не для других сертификатов, которые вы можете выпустить позже.

**Почему это дефолт:** работает на любой файловой системе, не зависит от поддержки ACL, тривиально дебажится и легко восстанавливается вручную, если что-то сломалось.

**Trade-off:** приватный ключ теперь лежит в двух местах на диске (LE `archive/` и `/etc/hysteria/certs/`), и если deploy-hook когда-нибудь молча упадёт, Hysteria будет отдавать устаревший сертификат.

### `--cert-mode acl`

Что происходит:
- Скрипт проверяет, что целевая ФС действительно поддерживает POSIX ACL (пишет probe-файл и пробует `setfacl` против него; если не получается — **автоматически переключается на copy mode** с WARN).
- Для пользователя `hysteria` ставится traverse-бит (`x`, без `r`) на каждый каталог в цепочке: `/etc/letsencrypt/live`, `/etc/letsencrypt/archive` и на подкаталоги домена. `x` без `r` — это «войти можно, листинг нельзя». Hysteria видит только те файлы, путь к которым ему явно дан.
- Read-бит (`r`) ставится на каждый существующий версионированный файл в `/etc/letsencrypt/archive/<domain>/` (`privkey*.pem`, `fullchain*.pem`, `chain*.pem`, `cert*.pem`).
- Ставится **default ACL** на `/etc/letsencrypt/archive/<domain>/`, поэтому файлы, создаваемые будущими renewal'ами certbot, автоматически наследуют ACL. Без этого certbot создал бы `privkey2.pem` без ACL, и Hysteria через ~60 дней молча бы отвалился.
- После этого скрипт **верифицирует от имени пользователя `hysteria`** (`sudo -u hysteria test -r ...`), что симлинки `live/<domain>/fullchain.pem` и `privkey.pem` действительно читаются. Если верификация не прошла — откат на copy mode.
- Ставится минимальный deploy-hook, который только reload'ит `hysteria-server` (копирование файлов в ACL-режиме не нужно).

**Почему это не дефолт:** режим строже к окружению. Если у вас экзотическая ФС, unprivileged-контейнер или SELinux enforcing — ACL может молча перестать применяться после обновления пакета или `restorecon`. У copy-режима таких failure-модов нет.

**Когда выбирать ACL:** если вам нужен единственный источник правды для приватного ключа и вы на стандартной ext4/xfs/btrfs Debian/Ubuntu VPS.

**Fallback'и.** ACL-режим откатывается на copy-режим в любом из этих случаев, все с `[WARN]`:
- Нет бинаря `setfacl` после установки.
- Не получается создать probe-файл под `/etc/letsencrypt`.
- Вызов `setfacl` на probe не прошёл (ФС не поддерживает ACL).
- Пост-верификация чтения от имени `hysteria` не прошла.

---

## Идемпотентность и повторные запуски

Скрипт можно запускать повторно на том же хосте — это поддерживаемый сценарий.

- `certbot` вызывается с `--keep-until-expiring`, а скрипт ещё раньше шорт-сёркьютит выпуск, если валидный серт живёт больше 30 дней. Чтобы форсировать перевыпуск — `--force-renew`.
- Правила `ufw` добавляются идемпотентно — повторный запуск не дублирует их.
- Nginx vhost-файлы намеренно перезаписываются — в этом и смысл. Предыдущее содержимое лежит в timestamped-бэкапе.
- Upstream-установщик Hysteria сам определяет существующую инсталляцию и пропускает тяжёлую работу; плюс этот скрипт дополнительно пропускает шаг установки целиком, если бинарь `hysteria` уже в `$PATH`.
- Systemd drop-in перезаписывается при каждом запуске.
- ACL-команды аддитивны и идемпотентны; повторные запуски не накапливают мусор.

Единственное, что **не** идемпотентно между запусками — каталог бэкапа: новый создаётся каждый раз с timestamp-суффиксом. Это сделано намеренно — каждый запуск оставляет независимую точку восстановления.

---

## Что захарденено

### Nginx TLS

- `ssl_protocols TLSv1.2 TLSv1.3` — никакого SSLv3, TLS 1.0/1.1.
- AEAD-only cipher suite (AES-GCM + CHACHA20-POLY1305), `ssl_prefer_server_ciphers off` (выбор за клиентом — современная рекомендация).
- `ssl_session_tickets off` — никакой возни с ротацией ключей session ticket, forward secrecy сохранена.
- OCSP stapling (`ssl_stapling on`, `ssl_stapling_verify on`), с `resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off`.
- `Strict-Transport-Security: max-age=63072000; includeSubDomains` (2 года).
- `X-Content-Type-Options: nosniff`.
- `X-Frame-Options: DENY`.
- `Referrer-Policy: no-referrer`.
- `Permissions-Policy: interest-cohort=()`.

### Скрипт

- `set -Eeuo pipefail`.
- `trap ERR`, который печатает упавшую строку и путь к бэкапу, чтобы откатиться.
- Весь пользовательский ввод валидируется (FQDN regex, email regex, диапазон порта, enum для cert-mode).
- `--site-title` и `--domain` HTML-escape'ятся перед подстановкой в статус-страницу — никакого XSS.
- `--password` маскируется в логах, спрашивается через `read -s` в интерактивном режиме и пишется в файл `mode 640 root:hysteria` под `umask 077`.
- Upstream-установщик Hysteria скачивается в temp и проверяется на наличие `#!` перед запуском.
- UFW проверяет, что SSH-правило поставлено в очередь, до включения firewall.

---

## Бэкапы и восстановление

Каждый запуск создаёт `/root/hysteria-vps-bootstrap-backup-<YYYYMMDD-HHMMSS>/` со следующим содержимым:

- `nginx/` — полная копия `/etc/nginx` на момент до запуска.
- `hysteria/` — полная копия `/etc/hysteria` (если существовал).
- `letsencrypt-meta/` — `renewal/` и `renewal-hooks/` из `/etc/letsencrypt`. Приватные ключи сами по себе **не** копируются (они нигде не дублируются зря).

Откатить изменения nginx:

```bash
sudo cp -a /root/hysteria-vps-bootstrap-backup-<ts>/nginx/. /etc/nginx/
sudo nginx -t && sudo systemctl reload nginx
```

Откатить конфиг hysteria:

```bash
sudo cp -a /root/hysteria-vps-bootstrap-backup-<ts>/hysteria/. /etc/hysteria/
sudo systemctl restart hysteria-server
```

---

## Проверка

Шаг `verify_services` скрипта гоняет все эти проверки автоматически. Если нужно руками:

```bash
# hysteria-server
systemctl status hysteria-server --no-pager -l
journalctl -u hysteria-server -n 50 --no-pager
ss -ulnp | grep :8443

# nginx + HTTPS
systemctl status nginx --no-pager -l
curl -I https://your-domain.com

# Детали TLS-хендшейка (снаружи)
openssl s_client -connect your-domain.com:443 -servername your-domain.com -tls1_3 </dev/null 2>/dev/null | openssl x509 -noout -dates -issuer -subject

# Серт реально читается пользователем hysteria (особенно полезно для ACL-режима)
sudo -u hysteria test -r /etc/letsencrypt/live/your-domain.com/privkey.pem && echo OK || echo FAIL
```

---

## Настройка клиента

Протестировано с Surge; те же параметры подходят любому Hysteria 2 клиенту.

- **Protocol:** Hysteria 2
- **Server Address:** IP VPS (часто надёжнее, чем домен, особенно в сетях, которые ломают DNS)
- **Port:** то, что передали в `--port`
- **Password:** тот же, что из `--password-file`
- **Custom TLS SNI:** ваш домен
- **IP Version:** IPv4 Only, если нет явной причины использовать v6

---

## Диагностика проблем

**Certbot упал с «Invalid response from …».** A-запись домена не указывает на этот VPS, либо порт 80 закрыт на уровне облачного firewall. DNS-preflight должен был это поймать — если вы его обошли или он прошёл, но валидатор Let's Encrypt всё равно падает, проверяйте облачный firewall.

**`hysteria-server` активен, но подключения не идут.** Проверьте `ss -ulnp | grep :<port>`. Если пусто — сервис запущен, но не биндится, обычно это проблема прав на TLS-файлы. Перезапустите с `--cert-mode copy`, чтобы обойти ACL-проблемы, или запустите `sudo -u hysteria test -r /etc/letsencrypt/live/<domain>/privkey.pem`, чтобы увидеть реальную ошибку доступа.

**HTTPS работает в браузере, но `curl -I https://<domain>` с самого VPS возвращает ошибку соединения.** Почти всегда IPv6: у VPS есть AAAA-запись, указывающая куда-то не туда, а nginx биндится только на v4. Либо добавьте `listen [::]:443 ssl;` (уже есть в хардененном vhost) и почините DNS, либо отключите v6 на хосте.

**ACL-режим молча перестал работать примерно через 60 дней.** Certbot сделал renewal и создал `privkey2.pem` в `archive/` без наследования ACL. Такого быть не должно, потому что скрипт ставит default ACL на каталог archive — но если случилось, проверьте `getfacl /etc/letsencrypt/archive/<domain>/` и убедитесь, что запись `default:user:hysteria:r--` на месте. Если её снесли (обновление пакета, ручной `setfacl --remove-all`) — перезапустите bootstrap или переприменить ACL руками.

**«Let's Encrypt rate limit exceeded».** Вы много раз запускали скрипт без защиты `--force-renew` — это про старые версии. Текущая версия идемпотентна и не будет перевыпускать валидный сертификат. Дождитесь окончания rate-limit и перезапустите — выпуск будет пропущен, и скрипт только починит downstream-состояние.

**`ufw` заблокировал SSH.** Скрипт ставит SSH-правило в очередь и отказывается включать firewall, если правила нет, так что этого быть не должно. Если всё же произошло (например, сработало заранее существующее deny-правило) — восстанавливайте SSH через консоль облачного провайдера.

---

## Заметки по безопасности

- Скрипт рассчитан на сценарий «VPS принадлежит вам». Это **не** security appliance для мультитенантного окружения. В частности, любой, у кого есть `root` на хосте, может прочитать `/etc/hysteria/config.yaml`.
- Пароль Hysteria — фактически единственный фактор аутентификации. Берите его из менеджера паролей, доставляйте через `--password-file` и ротируйте, если утёк.
- Приватные ключи Let's Encrypt лежат в `/etc/letsencrypt/archive/<domain>/`. В режиме `copy` вторая копия живёт в `/etc/hysteria/certs/`. В режиме `acl` существует только оригинал.
- Никакого fail2ban, rate-limit на Nginx, IDS. Если ваша модель угроз этого требует — добавляйте отдельно, это намеренно вне scope bootstrap-скрипта.
- SELinux не поддерживается. Если вы на дистрибутиве с SELinux enforcing — вы сами по себе, заводите issue.

---

## Удаление

Отдельного one-shot uninstaller'а нет (осознанное решение). Чтобы откатить то, что сделал скрипт:

```bash
# Остановить и отключить hysteria
sudo systemctl disable --now hysteria-server
sudo rm -f /etc/systemd/system/hysteria-server.service.d/override.conf
sudo systemctl daemon-reload

# Удалить бинарь hysteria (его ставит upstream-установщик)
sudo bash -c 'command -v hysteria && hysteria --help >/dev/null'  # посмотреть, что установлено
sudo rm -f /usr/local/bin/hysteria
sudo rm -rf /etc/hysteria
sudo userdel hysteria 2>/dev/null || true

# Удалить nginx vhost
sudo rm -f /etc/nginx/sites-enabled/<domain> /etc/nginx/sites-available/<domain>
sudo systemctl reload nginx

# Удалить certbot deploy-hook
sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-*-<domain>.sh

# Опционально: отозвать сертификат
sudo certbot revoke --cert-name <domain>
sudo certbot delete --cert-name <domain>

# Опционально: закрыть UDP-порт
sudo ufw delete allow <port>/udp
```

`nginx`, `certbot` и `ufw` не удаляйте, если не уверены, что они вам не нужны.

---

## Лицензия

См. [LICENSE](LICENSE). Использование — на ваш риск; перед прод-запуском сверьте конфигурацию со своей политикой безопасности.

## GitHub About

Готовые формулировки для поля About репозитория лежат в [GITHUB_REPO_META.md](GITHUB_REPO_META.md).
