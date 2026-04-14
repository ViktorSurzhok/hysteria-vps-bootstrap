# Метаданные для публичного репозитория на GitHub

Скопируйте текст ниже в настройки репозитория: **Settings** нельзя для чужих форков, для своего: на главной репозитория справа **About** → иконка шестерёнки.

## Short description (поле «Description», до ~350 символов)

**EN (универсально для GitHub):**

> One-shot bootstrap: Hysteria 2 + Nginx + Let's Encrypt + status page on a fresh Ubuntu/Debian VPS. UFW, systemd, copy-paste Surge hints.

**RU (если хотите русский About):**

> Один скрипт: Hysteria 2, Nginx, Let's Encrypt и статус-страница на чистом Ubuntu/Debian VPS. UFW, systemd, подсказки для Surge.

## Topics (теги)

Рекомендуемые topics для поиска:

`hysteria` `hysteria2` `vps` `nginx` `letsencrypt` `certbot` `bash` `ubuntu` `debian` `bootstrap` `surge` `proxy` `self-hosted` `tls`

## Long description (для README intro или «About» на сайте проекта)

**EN:**

This repository ships a single, opinionated shell script that turns a blank **Ubuntu/Debian** VPS into a small **Hysteria 2** edge node with a real **TLS** identity: **Nginx** serves a polished status page on your domain, **Certbot** obtains **Let's Encrypt** certificates, and **Hysteria** reuses those certificates for QUIC-style UDP transport with password auth and a sane **systemd** restart policy. Firewall rules for SSH, HTTP/S, and your Hysteria UDP port are applied with **UFW**. The goal is not a universal control plane — it is a **fast, repeatable** baseline you can fork and harden for your own threat model.

**RU:**

В репозитории — один осознанно «жёсткий» bash-скрипт, который превращает пустой **Ubuntu/Debian** VPS в компактный **edge-узел Hysteria 2** с нормальным **TLS** на домене: **Nginx** отдаёт аккуратную статус-страницу, **Certbot** выпускает **Let's Encrypt**, **Hysteria** использует те же сертификаты для UDP-транспорта с паролем и предсказуемой политикой **systemd**. **UFW** открывает SSH, 80/443 и выбранный UDP-порт. Это не панель управления инфраструктурой, а **быстрый повторяемый каркас**, который можно форкнуть и довести до своих требований по безопасности и отказоустойчивости.

## Website (опционально)

Если есть отдельный лендинг или документация — укажите URL. Иначе можно оставить пустым или поставить ссылку на сырой скрипт:

`https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/hysteria-vps-bootstrap/main/setup-hysteria.sh`

(замените `YOUR_GITHUB_USERNAME`.)
