# Hysteria VPS Bootstrap

Быстрый bootstrap-скрипт для развёртывания **Hysteria 2** + **Nginx** + **Let's Encrypt** + статусной HTML-страницы на чистом VPS (Ubuntu/Debian, `apt`).

## Что делает скрипт

- ставит `nginx`, `certbot`, базовые утилиты и `ufw`
- поднимает статусную страницу на домене
- получает SSL через Let's Encrypt (плагин `nginx`)
- ставит Hysteria 2 через официальный установщик
- настраивает Hysteria на выбранном UDP-порту с TLS сертификатом домена
- включает автозапуск сервисов и политику перезапуска для `hysteria-server`
- выводит в консоль параметры для подключения клиента

## Требования

Перед запуском:

- чистый **Ubuntu/Debian** VPS с `apt-get`
- **root** (или `sudo`)
- домен уже указывает на IP VPS через **A** запись
- на стороне облака/хостинга открыты порты:
  - `22/tcp`
  - `80/tcp`
  - `443/tcp`
  - выбранный UDP-порт (по умолчанию `8443/udp`)

## Быстрый запуск

```bash
sudo bash setup-hysteria.sh \
  --domain static.example.com \
  --email admin@example.com \
  --password 'StrongPasswordHere' \
  --port 8443 \
  --site-title "Инфраструктурный узел активен."
```

## Параметры

| Параметр      | Обязательный | Описание                          |
|---------------|--------------|-----------------------------------|
| `--domain`    | да           | домен для сайта и TLS           |
| `--email`     | да           | email для Let's Encrypt         |
| `--password`  | да           | пароль для Hysteria             |
| `--port`      | нет          | UDP-порт Hysteria (по умолчанию 8443) |
| `--webroot`   | нет          | путь к корню сайта              |
| `--site-title`| нет          | подпись на статусной странице   |

## Пример

```bash
sudo bash setup-hysteria.sh \
  --domain static.lamp-labs.pro \
  --email you@example.com \
  --password 'your-secure-password' \
  --port 8443 \
  --site-title "Сервер работает нормально."
```

## Что будет на странице

- бейдж **ONLINE**
- домен и подпись
- **Server IP**, **Hysteria Port**, **TLS SNI**, **Environment**
- время генерации страницы

## Проверка

**Hysteria**

```bash
systemctl status hysteria-server --no-pager -l
journalctl -u hysteria-server -f --no-pager
```

**Nginx**

```bash
systemctl status nginx --no-pager -l
curl -I https://your-domain.com
```

**Порты**

```bash
ss -tulnp | grep -E ':80|:443|:8443'
```

## Рекомендуемые настройки Surge

- **Protocol:** Hysteria 2  
- **Server Address:** IP VPS (часто надёжнее, чем только домен)  
- **Port:** как в `--port`  
- **Password:** тот же, что при установке  
- **Custom TLS SNI:** ваш домен  
- **IP Version:** IPv4 Only (при необходимости)

## One-liner с GitHub

Подставьте свой пользователь/организацию вместо `YOUR_GITHUB_USERNAME`.

**curl**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/hysteria-vps-bootstrap/main/setup-hysteria.sh) \
  --domain static.example.com \
  --email admin@example.com \
  --password 'StrongPasswordHere' \
  --port 8443
```

**wget**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/hysteria-vps-bootstrap/main/setup-hysteria.sh) \
  --domain static.example.com \
  --email admin@example.com \
  --password 'StrongPasswordHere' \
  --port 8443
```

## Важно

- Скрипт рассчитан на **чистый** сервер: перезаписывает vhost для домена и отключает дефолтный сайт Nginx.
- Если на VPS уже есть сайты или reverse proxy — **адаптируйте** конфиг вручную или не запускайте скрипт вслепую.
- Пароль в командной строке может быть виден в `ps` / истории — для продакшена рассмотрите передачу секрета из файла (отдельная доработка).
- Для максимальной проходимости сетей иногда переводят Hysteria на **443/udp** (конфликт с QUIC/другими сервисами — оценивайте отдельно).

## Лицензия

См. [LICENSE](LICENSE). Использование — на ваш риск; перед продакшеном проверьте конфигурацию под свои требования и политику безопасности.

## Описание для GitHub (About)

Готовые формулировки для поля **Description**, **Website** и раздела About — в файле [GITHUB_REPO_META.md](GITHUB_REPO_META.md).
