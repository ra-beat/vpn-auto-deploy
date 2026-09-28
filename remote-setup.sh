#!/usr/bin/env bash
# ==============================================================================
# remote-setup.sh — Скрипт установки AmneziaWG VPN на чистый VPS (Ubuntu)
# Выполняется УДАЛЁННО на сервере через SSH (запускается из local-deploy.sh)
# ==============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Константы — изменяйте только если хотите другую сеть/порт
# ──────────────────────────────────────────────────────────────────────────────
VPN_DIR="/opt/my-vpn"                          # Корневая директория VPN
WG_PORT=51820                                  # UDP-порт AmneziaWG
SERVER_TUNNEL_IP="10.8.0.1"                    # IP сервера внутри VPN-туннеля
SERVER_SUBNET="10.8.0.0/24"                    # Подсеть туннеля
CONTAINER_NAME="amnezia-wg"                    # Имя Docker-контейнера

log()  { echo "[SETUP] $*"; }
warn() { echo "[WARN]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# Запрет запуска не из-под root
[[ "${EUID}" -ne 0 ]] && err "Скрипт должен запускаться от root."

log "=================================================="
log "  Начало установки AmneziaWG VPN"
log "  $(date '+%Y-%m-%d %H:%M:%S')"
log "=================================================="

# ==============================================================================
# Определяем основной сетевой интерфейс сервера (нужен для NAT)
# ==============================================================================
IFACE=$(ip route get 8.8.8.8 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ -z "${IFACE}" ]] && err "Не удалось определить основной сетевой интерфейс."
log "Основной сетевой интерфейс: ${IFACE}"

# ==============================================================================
# 1. Обновляем систему и устанавливаем базовые пакеты
# ==============================================================================
log "Обновляем систему..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" \
                       -o Dpkg::Options::="--force-confold"

log "Устанавливаем зависимости..."
apt-get install -y -qq \
    curl wget ca-certificates gnupg lsb-release \
    wireguard-tools iptables iptables-persistent \
    iproute2 kmod jq

# ==============================================================================
# 2. Устанавливаем Docker (официальный скрипт get.docker.com)
# ==============================================================================
if ! command -v docker &>/dev/null; then
    log "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log "Docker установлен: $(docker --version)"
else
    log "Docker уже установлен: $(docker --version)"
fi

# Определяем рабочую команду docker compose (плагин v2 или старый v1)
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    log "Используем: docker compose (плагин v2)"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
    log "Используем: docker-compose (v1)"
else
    log "Устанавливаем docker-compose-plugin..."
    apt-get install -y -qq docker-compose-plugin
    COMPOSE_CMD="docker compose"
fi

# ==============================================================================
# 3. Создаём структуру директорий
# ==============================================================================
log "Создаём директорию ${VPN_DIR}..."
mkdir -p "${VPN_DIR}/wg-config"    # Конфиги WireGuard/AmneziaWG
mkdir -p "${VPN_DIR}/clients"      # Конфиги клиентов (скачиваются локально)

# ==============================================================================
# 4. Включаем IP-форвардинг на уровне хоста (обязательно для NAT)
# ==============================================================================
log "Включаем IP-форвардинг..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Добавляем в /etc/sysctl.conf если ещё нет — настройка переживёт перезагрузку
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

# ==============================================================================
# 5. Генерируем серверные ключи
#    Ключи WireGuard и AmneziaWG используют одинаковый формат Curve25519
# ==============================================================================
log "Генерируем серверные ключи..."
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(echo "${SERVER_PRIVKEY}" | wg pubkey)
log "Серверные ключи успешно сгенерированы."

# ==============================================================================
# 6. Генерируем параметры обфускации AmneziaWG
#    Эти параметры скрывают трафик AWG от DPI-систем (ТСПУ, DPI-блокировки)
# ==============================================================================
log "Генерируем параметры обфускации..."

# Jc: количество junk-пакетов в начале сессии (рекомендуется 3-7)
JC=$(( (RANDOM % 5) + 3 ))

# Jmin/Jmax: диапазон размера junk-пакетов в байтах
JMIN=$(( (RANDOM % 30) + 40 ))      # 40-69 байт
JMAX=$(( (RANDOM % 100) + 100 ))    # 100-199 байт (всегда > Jmin)
[[ ${JMAX} -gt 1280 ]] && JMAX=1280

# S1/S2: размер дополнительного junk в init/response пакетах (15-150 байт)
S1=$(( (RANDOM % 80) + 15 ))
S2=$(( (RANDOM % 80) + 15 ))

# H1-H4: магические заголовки — должны быть уникальными случайными числами
# RANDOM в bash даёт max 32767, перемножаем для большего диапазона
H1=$(( (RANDOM + 1) * (RANDOM + 2) + 100 ))
H2=$(( (RANDOM + 3) * (RANDOM + 4) + 200 ))
H3=$(( (RANDOM + 5) * (RANDOM + 6) + 300 ))
H4=$(( (RANDOM + 7) * (RANDOM + 8) + 400 ))

log "Параметры: Jc=${JC}, Jmin=${JMIN}, Jmax=${JMAX}, S1=${S1}, S2=${S2}"

# ==============================================================================
# 7. Определяем публичный IPv4-адрес сервера
#    ВАЖНО: используем только IPv4 (флаг -4). IPv6 не используется.
# ==============================================================================
log "Определяем публичный IPv4-адрес сервера..."
PUBLIC_IP=""
for srv in "api4.ipify.org" "ipv4.icanhazip.com" "ifconfig.me" "api.ipify.org"; do
    PUBLIC_IP=$(curl -4 -s --max-time 5 "https://${srv}" 2>/dev/null | tr -d '[:space:]') || true
    # Проверяем что получили именно IPv4 (не IPv6)
    if [[ "${PUBLIC_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    fi
    PUBLIC_IP=""
done
# Fallback: берём первый IPv4 из списка адресов хоста
[[ -z "${PUBLIC_IP}" ]] && PUBLIC_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{print $NF}' | head -1)
[[ -z "${PUBLIC_IP}" ]] && PUBLIC_IP=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1)
[[ -z "${PUBLIC_IP}" ]] && err "Не удалось определить публичный IPv4-адрес сервера."
log "Публичный IPv4 сервера: ${PUBLIC_IP}"

# ==============================================================================
# 8. Создаём конфиг сервера wg0.conf с параметрами AmneziaWG
# ==============================================================================
log "Создаём /opt/my-vpn/wg-config/wg0.conf..."

cat > "${VPN_DIR}/wg-config/wg0.conf" << WGCONF_EOF
[Interface]
# Приватный ключ сервера (СЕКРЕТ — не передавать клиентам)
PrivateKey = ${SERVER_PRIVKEY}
# IP-адрес сервера внутри VPN-туннеля
Address = ${SERVER_TUNNEL_IP}/24
# UDP-порт, на котором слушает AmneziaWG
ListenPort = ${WG_PORT}

# ── Параметры обфускации AmneziaWG ──────────────────────────────────
# Junk-пакеты маскируют начало соединения под случайный трафик
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
# Дополнительный мусор в init/response пакетах
S1 = ${S1}
S2 = ${S2}
# Уникальные магические заголовки (идентификаторы сессии)
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

# ── NAT и форвардинг — разрешают выход клиентов в интернет ──────────
# MASQUERADE: подменяет src IP клиентов на IP сервера при выходе в инет
PostUp   = iptables -t nat -A POSTROUTING -s ${SERVER_SUBNET} -o ${IFACE} -j MASQUERADE; \
           iptables -A FORWARD -i wg0 -j ACCEPT; \
           iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_SUBNET} -o ${IFACE} -j MASQUERADE; \
           iptables -D FORWARD -i wg0 -j ACCEPT; \
           iptables -D FORWARD -o wg0 -j ACCEPT

# [Peer] блоки добавляются динамически через manage.sh
WGCONF_EOF

chmod 600 "${VPN_DIR}/wg-config/wg0.conf"
log "Конфиг сервера создан."

# ==============================================================================
# 9. Сохраняем серверные переменные для использования в manage.sh
# ==============================================================================
cat > "${VPN_DIR}/server.env" << SRVENV_EOF
SERVER_PUBKEY="${SERVER_PUBKEY}"
SERVER_PRIVKEY="${SERVER_PRIVKEY}"
PUBLIC_IP="${PUBLIC_IP}"
WG_PORT="${WG_PORT}"
SERVER_SUBNET="${SERVER_SUBNET}"
SERVER_TUNNEL_IP="${SERVER_TUNNEL_IP}"
IFACE="${IFACE}"
JC="${JC}"
JMIN="${JMIN}"
JMAX="${JMAX}"
S1="${S1}"
S2="${S2}"
H1="${H1}"
H2="${H2}"
H3="${H3}"
H4="${H4}"
SRVENV_EOF

chmod 600 "${VPN_DIR}/server.env"
log "server.env создан."

# ==============================================================================
# 10. Создаём Dockerfile для AmneziaWG
#     Используем кастомный образ, т.к. официальный образ не всегда стабилен.
#     Устанавливаем amneziawg-tools из официальных GitHub Releases.
# ==============================================================================
log "Создаём Dockerfile для AmneziaWG..."

cat > "${VPN_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
# ── Стадия сборки: компилируем awg и awg-quick из исходников ──────────────────
# Сборка из исходников — единственный надёжный способ: не зависит от
# формата имён релизных пакетов на GitHub и гарантирует актуальную версию.
FROM ubuntu:22.04 AS builder

LABEL org.opencontainers.image.description="AmneziaWG VPN Server"

ENV DEBIAN_FRONTEND=noninteractive

# Инструменты для сборки C-кода и git для клонирования репозитория
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        pkg-config \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Клонируем amneziawg-tools (форк wireguard-tools с поддержкой AWG-параметров)
# --depth 1 — только последний коммит, не тянем историю
#
# ВАЖНО: Makefile собирает бинарник с именем 'wg' (не 'awg'),
# поэтому мы используем 'make install DESTDIR' и нормализуем имена.
RUN git clone --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-tools.git \
        /tmp/awg-src \
    # Компилируем всё: бинарник + скрипт wg-quick/awg-quick
    && make -C /tmp/awg-src/src \
    # Устанавливаем в временный DESTDIR — это правильно раскладывает все файлы
    && make -C /tmp/awg-src/src install DESTDIR=/tmp/awg-inst \
    # Выводим список установленных файлов (для отладки)
    && echo '=== Installed files ===' && find /tmp/awg-inst -type f \
    # Нормализуем имена в /tmp/awg-bin/: wg→awg, wg-quick→awg-quick
    && mkdir -p /tmp/awg-bin \
    # Ищем главный бинарник: сначала 'awg', затем 'wg'
    && for f in awg wg; do \
         found=$(find /tmp/awg-inst -type f -name "$f" ! -name '*-*' | head -1); \
         [ -n "$found" ] && cp "$found" /tmp/awg-bin/awg && break; \
       done \
    # Ищем скрипт: сначала 'awg-quick', затем 'wg-quick'
    && for f in awg-quick wg-quick; do \
         found=$(find /tmp/awg-inst -type f -name "$f" | head -1); \
         [ -n "$found" ] && cp "$found" /tmp/awg-bin/awg-quick && break; \
       done \
    # Если awg-quick вообще не нашёлся — создаём минимальный враппер
    && if [ ! -f /tmp/awg-bin/awg-quick ]; then \
         printf '#!/bin/sh\nexec wg-quick "$@"\n' > /tmp/awg-bin/awg-quick; \
         echo 'WARN: awg-quick not found, created fallback wrapper'; \
       fi \
    && strip /tmp/awg-bin/awg \
    && chmod +x /tmp/awg-bin/awg /tmp/awg-bin/awg-quick \
    && echo '=== Final binaries ===' && ls -la /tmp/awg-bin/

# ── Финальный образ: только рантайм-зависимости ──────────────────────────────
# Компилятор и git не включаются — финальный образ остаётся лёгким.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Рантайм: сетевые утилиты и iptables для NAT
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables \
        iproute2 \
        wireguard-tools \
        kmod \
        bash \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Копируем нормализованные бинарники из стадии builder:
# awg       — основной бинарник (аналог wg, с поддержкой Jc/Jmin/Jmax/S1/S2/H1-H4)
# awg-quick — скрипт управления интерфейсом (аналог wg-quick, читает AWG-поля)
COPY --from=builder /tmp/awg-bin/awg       /usr/local/bin/awg
COPY --from=builder /tmp/awg-bin/awg-quick  /usr/local/bin/awg-quick
RUN chmod +x /usr/local/bin/awg /usr/local/bin/awg-quick \
    && echo 'awg version:' && awg --version || true

# Копируем точку входа контейнера
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Конфиги монтируются снаружи (с хоста)
VOLUME ["/etc/amnezia/amneziawg"]

# AmneziaWG слушает на UDP-порту (при network_mode: host порт открыт на хосте)
EXPOSE 51820/udp

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE_EOF

# ==============================================================================
# 11. Создаём entrypoint.sh — точка входа контейнера
# ==============================================================================
log "Создаём entrypoint.sh..."

cat > "${VPN_DIR}/entrypoint.sh" << 'ENTRY_EOF'
#!/usr/bin/env bash
# entrypoint.sh — запускается при старте Docker-контейнера AmneziaWG

set -e

WG_CONF="/etc/amnezia/amneziawg/wg0.conf"

echo "[ENTRY] Запуск AmneziaWG контейнера..."

# Загружаем модуль ядра. В privileged-режиме это загружает модуль на HOST-системе.
# Сначала пробуем amneziawg (AWG), затем wireguard (стандартный WG как fallback)
modprobe amneziawg 2>/dev/null && echo "[ENTRY] Модуль amneziawg загружен." \
    || { modprobe wireguard 2>/dev/null && echo "[ENTRY] Используем модуль wireguard (fallback)." \
    || echo "[ENTRY] WARN: Не удалось загрузить модуль ядра — используем userspace."; }

# Проверяем наличие конфига
if [[ ! -f "${WG_CONF}" ]]; then
    echo "[ENTRY] ERROR: Конфиг не найден: ${WG_CONF}"
    exit 1
fi

echo "[ENTRY] Поднимаем интерфейс wg0..."

# Пробуем запустить через awg-quick (AmneziaWG-вариант wg-quick)
# Если awg-quick недоступен — fallback на стандартный wg-quick
if command -v awg-quick &>/dev/null; then
    awg-quick up "${WG_CONF}" && echo "[ENTRY] wg0 поднят через awg-quick." \
        || echo "[ENTRY] WARN: awg-quick up завершился с ошибкой."
else
    wg-quick up "${WG_CONF}" && echo "[ENTRY] wg0 поднят через wg-quick (fallback)." \
        || echo "[ENTRY] WARN: wg-quick up завершился с ошибкой."
fi

echo "[ENTRY] AmneziaWG запущен. Ожидаем соединения..."

# Graceful shutdown: при получении SIGTERM/SIGINT опускаем интерфейс
cleanup() {
    echo "[ENTRY] Получен сигнал остановки — опускаем wg0..."
    if command -v awg-quick &>/dev/null; then
        awg-quick down "${WG_CONF}" 2>/dev/null || true
    else
        wg-quick down "${WG_CONF}" 2>/dev/null || true
    fi
    echo "[ENTRY] wg0 остановлен."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Держим контейнер запущенным
exec tail -f /dev/null &
wait $!
ENTRY_EOF

chmod +x "${VPN_DIR}/entrypoint.sh"
log "entrypoint.sh создан."

# ==============================================================================
# 12. Создаём docker-compose.yml
#     network_mode: host — контейнер использует сеть хоста напрямую,
#     интерфейс wg0 создаётся на хосте, порты не нужно маппить явно.
# ==============================================================================
log "Создаём docker-compose.yml..."

cat > "${VPN_DIR}/docker-compose.yml" << COMPOSE_EOF
# docker-compose.yml для AmneziaWG
# Примечание: поле 'version' удалено — оно устарело в Docker Compose v2+
# Примечание: sysctls НЕ используются при network_mode: host
#   (Docker запрещает менять sysctl хостового namespace через compose).
#   IP-форвардинг включается напрямую через sysctl на хосте в remote-setup.sh.

services:
  ${CONTAINER_NAME}:
    # Собираем локальный образ из нашего Dockerfile
    build:
      context: .
      dockerfile: Dockerfile
    image: amnezia-wg-local:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped

    # host-сеть: контейнер разделяет сетевой namespace хоста напрямую.
    # wg0 создаётся на хосте — входящий UDP:51820 сразу видит интерфейс.
    # Явный port mapping не нужен.
    network_mode: host

    # Привилегированный режим: нужен для создания сетевых интерфейсов
    # и загрузки модулей ядра (modprobe amneziawg/wireguard)
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    volumes:
      # Конфиги монтируем с хоста в контейнер (wg0.conf читается awg-quick)
      - /opt/my-vpn/wg-config:/etc/amnezia/amneziawg
      # Модули ядра хоста — только чтение, нужны для modprobe
      - /lib/modules:/lib/modules:ro

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_EOF

log "docker-compose.yml создан."

# ==============================================================================
# 13. Собираем и запускаем контейнер
# ==============================================================================
log "Собираем Docker-образ AmneziaWG (это займёт 1-3 минуты)..."
cd "${VPN_DIR}"

${COMPOSE_CMD} build --no-cache 2>&1 | grep -E '(Step|RUN|Successfully|ERROR|WARN)' || true

log "Запускаем контейнер..."
${COMPOSE_CMD} up -d

# Ждём, пока контейнер будет в статусе running
log "Ожидаем запуска контейнера (до 60 сек)..."
for i in $(seq 1 60); do
    STATUS=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "none")
    if [[ "${STATUS}" == "running" ]]; then
        log "Контейнер ${CONTAINER_NAME} запущен."
        break
    fi
    if [[ "${STATUS}" == "exited" || "${STATUS}" == "dead" ]]; then
        warn "Контейнер завершился аварийно. Проверяем логи..."
        docker logs "${CONTAINER_NAME}" 2>&1 | tail -20
        err "Контейнер не запустился."
    fi
    sleep 1
done

# Небольшая пауза для инициализации интерфейса wg0
sleep 3

# Проверяем, что интерфейс wg0 действительно поднят на хосте
if ip link show wg0 &>/dev/null 2>&1; then
    log "Интерфейс wg0 активен на хосте."
elif docker exec "${CONTAINER_NAME}" ip link show wg0 &>/dev/null 2>&1; then
    log "Интерфейс wg0 активен в контейнере."
else
    warn "Интерфейс wg0 не обнаружен. Проверьте: docker logs ${CONTAINER_NAME}"
fi

# ==============================================================================
# 14. Создаём скрипт управления /opt/my-vpn/manage.sh
#     Этот скрипт отвечает за добавление новых VPN-клиентов
# ==============================================================================
log "Создаём скрипт управления manage.sh..."

# ── manage.sh начинается здесь (встроен через heredoc) ──────────────────────
cat > "${VPN_DIR}/manage.sh" << 'MANAGE_SCRIPT_EOF'
#!/usr/bin/env bash
# ==============================================================================
# manage.sh — Управление VPN-клиентами AmneziaWG
# Использование: bash /opt/my-vpn/manage.sh <имя_клиента>
# ==============================================================================
set -euo pipefail

VPN_DIR="/opt/my-vpn"
CLIENT_DIR="${VPN_DIR}/clients"         # Готовые .conf и .png файлы
KEYS_DIR="${VPN_DIR}/keys"              # Ключи клиентов (каждый в своей поддиректории)
WG_CONF="${VPN_DIR}/wg-config/wg0.conf"
ENV_FILE="${VPN_DIR}/server.env"
LAST_IP_FILE="${VPN_DIR}/.last_client_octet"
CONTAINER_NAME="amnezia-wg"

log()  { echo "[MANAGE] $*"; }
warn() { echo "[WARN]   $*"; }
err()  { echo "[ERROR]  $*" >&2; exit 1; }

# ── Проверяем аргументы ──────────────────────────────────────────────────────
[[ $# -lt 1 ]] && err "Использование: $0 <имя_клиента>"
CLIENT_NAME="$1"
[[ -z "${CLIENT_NAME}" ]] && err "Имя клиента не может быть пустым."

# ── Загружаем переменные сервера из server.env ───────────────────────────────
[[ ! -f "${ENV_FILE}" ]] && err "Файл ${ENV_FILE} не найден. Запустите remote-setup.sh."
# shellcheck disable=SC1090
source "${ENV_FILE}"

mkdir -p "${CLIENT_DIR}"
mkdir -p "${KEYS_DIR}"

log "Создаём клиента: ${CLIENT_NAME}"

# ── Проверяем: не существует ли уже такой клиент ────────────────────────────
if [[ -f "${CLIENT_DIR}/${CLIENT_NAME}.conf" ]]; then
    warn "Клиент '${CLIENT_NAME}' уже существует."
    warn "Пересоздаём ключи и конфиг."
fi

# ── Выдаём следующий свободный IP-адрес из пула ──────────────────────────────
if [[ ! -f "${LAST_IP_FILE}" ]]; then
    LAST_OCTET=1
else
    LAST_OCTET=$(cat "${LAST_IP_FILE}")
fi

NEXT_OCTET=$(( LAST_OCTET + 1 ))
[[ ${NEXT_OCTET} -gt 254 ]] && err "Исчерпан пул адресов 10.8.0.x (максимум 253 клиента)."

CLIENT_TUNNEL_IP="10.8.0.${NEXT_OCTET}"
echo "${NEXT_OCTET}" > "${LAST_IP_FILE}"
log "IP клиента внутри туннеля: ${CLIENT_TUNNEL_IP}"

# ── Генерируем ключи клиента ─────────────────────────────────────────────────
log "Генерируем ключи..."
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "${CLIENT_PRIVKEY}" | wg pubkey)
CLIENT_PSK=$(wg genpsk)
log "Ключи клиента сгенерированы."

# ── Сохраняем ключи клиента в директорию keys/<client_name>/ ─────────────────
# Каждый клиент получает свою поддиректорию с отдельными файлами для ключей.
# Это позволяет легко ротировать или отозвать конкретный ключ.
CLIENT_KEYS_DIR="${KEYS_DIR}/${CLIENT_NAME}"
mkdir -p "${CLIENT_KEYS_DIR}"

# Приватный ключ — самое чувствительное, права только для root
echo "${CLIENT_PRIVKEY}" > "${CLIENT_KEYS_DIR}/private.key"
chmod 600 "${CLIENT_KEYS_DIR}/private.key"

# Публичный ключ — можно читать, нужен для добавления пира на сервере
echo "${CLIENT_PUBKEY}" > "${CLIENT_KEYS_DIR}/public.key"
chmod 644 "${CLIENT_KEYS_DIR}/public.key"

# Предварительно согласованный ключ — также чувствительный
echo "${CLIENT_PSK}" > "${CLIENT_KEYS_DIR}/preshared.key"
chmod 600 "${CLIENT_KEYS_DIR}/preshared.key"

# Метаданные клиента (IP, дата создания)
cat > "${CLIENT_KEYS_DIR}/info.txt" << META_EOF
client_name=${CLIENT_NAME}
tunnel_ip=${CLIENT_TUNNEL_IP}
created=$(date '+%Y-%m-%d %H:%M:%S')
server_ip=${PUBLIC_IP}
META_EOF

log "Ключи сохранены: ${CLIENT_KEYS_DIR}/"

# ── Добавляем пира в серверный конфиг wg0.conf ───────────────────────────────
log "Добавляем [Peer] в wg0.conf..."

cat >> "${WG_CONF}" << PEER_EOF

# ── Клиент: ${CLIENT_NAME} (добавлен: $(date '+%Y-%m-%d %H:%M:%S')) ──
[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_TUNNEL_IP}/32
PEER_EOF

log "Пир добавлен в конфиг."

# ── Применяем конфиг сервера без обрыва существующих соединений ──────────────
log "Применяем новую конфигурацию..."

if docker exec "${CONTAINER_NAME}" command -v awg &>/dev/null 2>&1; then
    docker exec "${CONTAINER_NAME}" bash -c \
        'awg syncconf wg0 <(awg-quick strip /etc/amnezia/amneziawg/wg0.conf)' \
        && log "awg syncconf применён успешно." \
        || {
            warn "awg syncconf не сработал, перезапускаем контейнер..."
            docker restart "${CONTAINER_NAME}"
            sleep 5
        }
elif docker exec "${CONTAINER_NAME}" command -v wg &>/dev/null 2>&1; then
    docker exec "${CONTAINER_NAME}" bash -c \
        'wg syncconf wg0 <(wg-quick strip /etc/amnezia/amneziawg/wg0.conf)' \
        && log "wg syncconf применён." \
        || {
            warn "wg syncconf не сработал, перезапускаем контейнер..."
            docker restart "${CONTAINER_NAME}"
            sleep 5
        }
else
    warn "awg/wg не найдены в контейнере — перезапускаем."
    docker restart "${CONTAINER_NAME}"
    sleep 5
fi

# ── Устанавливаем qrencode (нужен для генерации QR-кода) ─────────────────────
if ! command -v qrencode &>/dev/null; then
    log "Устанавливаем qrencode..."
    apt-get install -y -qq qrencode
fi

# ── Получаем список заблокированных IP с antifilter.download ─────────────────
log "Получаем список заблокированных IP с antifilter.download..."
ALLOWED_IPS=""

# Сначала пробуем текстовый список (более стабилен)
ALLOWED_IPS=$(curl -s --max-time 60 \
    "https://antifilter.download/list/ips.txt" 2>/dev/null \
    | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | paste -sd ',' - || echo "")

if [[ -n "${ALLOWED_IPS}" ]]; then
    log "Текстовый список загружен: $(echo "${ALLOWED_IPS}" | tr ',' '\n' | wc -l) записей."
fi

# Если текстовый список не сработал — пробуем JSON API
if [[ -z "${ALLOWED_IPS}" ]]; then
    warn "Текстовый список недоступен. Пробуем JSON API..."
    ANTIFILTER_JSON=$(curl -s --max-time 60 \
        "https://antifilter.download/api/ips" 2>/dev/null || echo "")

    if [[ -n "${ANTIFILTER_JSON}" ]] && echo "${ANTIFILTER_JSON}" | grep -qE '^\['; then
        ALLOWED_IPS=$(echo "${ANTIFILTER_JSON}" \
            | tr -d '[]"' \
            | tr ',' '\n' \
            | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
            | paste -sd ',' -)
        [[ -n "${ALLOWED_IPS}" ]] && \
            log "JSON API: $(echo "${ALLOWED_IPS}" | tr ',' '\n' | wc -l) записей."
    fi
fi

if [[ -z "${ALLOWED_IPS}" ]]; then
    warn "antifilter.download недоступен. Весь трафик идёт через VPN."
    ALLOWED_IPS="0.0.0.0/0"
fi

# ── Генерируем клиентский .conf файл ─────────────────────────────────────────
log "Генерируем клиентский конфиг..."

cat > "${CLIENT_DIR}/${CLIENT_NAME}.conf" << CLIENT_CONF_EOF
# ==============================================================================
# AmneziaWG конфигурация для клиента: ${CLIENT_NAME}
# Сгенерирована: $(date '+%Y-%m-%d %H:%M:%S')
# Сервер: ${PUBLIC_IP}
# ==============================================================================

[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
# Адрес клиента внутри VPN-туннеля (маска /32 — только этот адрес)
Address = ${CLIENT_TUNNEL_IP}/32
DNS = 1.1.1.1, 8.8.8.8

# ── Параметры обфускации AmneziaWG ──────────────────────────────────────────
# Эти значения ДОЛЖНЫ совпадать с серверными!
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${CLIENT_TUNNEL_IP}/32, ${ALLOWED_IPS}
PersistentKeepalive = 25
CLIENT_CONF_EOF

chmod 600 "${CLIENT_DIR}/${CLIENT_NAME}.conf"
log "Конфиг сохранён: ${CLIENT_DIR}/${CLIENT_NAME}.conf"

# ── Генерируем конфиг совместимости со стандартным WireGuard (для NekoBox и др.) ──
# NekoBox / SagerNet / wg-android НЕ понимают поля Jc/Jmin/Jmax/S1/S2/H1-H4
# Создаём чистый WireGuard конфиг без AWG-параметров обфускации
log "Генерируем WireGuard-совместимый конфиг (для NekoBox/SagerNet)..."

cat > "${CLIENT_DIR}/${CLIENT_NAME}_wg.conf" << WG_CONF_EOF
# ==============================================================================
# WireGuard конфигурация для клиента: ${CLIENT_NAME}
# Сгенерирована: $(date '+%Y-%m-%d %H:%M:%S')
# Сервер: ${PUBLIC_IP}
# ПРИМЕЧАНИЕ: Этот файл БЕЗ параметров обфускации AmneziaWG.
# Используйте для: NekoBox, SagerNet, wg-android, стандартных WG-клиентов.
# Для обфускации используйте основной файл ${CLIENT_NAME}.conf в AmneziaVPN.
# ==============================================================================

[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_TUNNEL_IP}/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${CLIENT_TUNNEL_IP}/32, ${ALLOWED_IPS}
PersistentKeepalive = 25
WG_CONF_EOF

chmod 600 "${CLIENT_DIR}/${CLIENT_NAME}_wg.conf"
log "WireGuard конфиг сохранён: ${CLIENT_DIR}/${CLIENT_NAME}_wg.conf"

# ── Генерируем QR-код из конфига ─────────────────────────────────────────────
# PNG-файл: импортируется в мобильных приложениях через камеру
# ASCII QR: отображается прямо в терминале для быстрого сканирования

log "Генерируем QR-код..."

# PNG — сохраняем рядом с .conf, скачивается вместе с ним
qrencode \
    --type=PNG \
    --size=10 \
    --margin=2 \
    --output="${CLIENT_DIR}/${CLIENT_NAME}.png" \
    < "${CLIENT_DIR}/${CLIENT_NAME}.conf"

chmod 600 "${CLIENT_DIR}/${CLIENT_NAME}.png"
log "QR PNG сохранён: ${CLIENT_DIR}/${CLIENT_NAME}.png"

# QR для WG-совместимого конфига (для NekoBox)
qrencode \
    --type=PNG \
    --size=10 \
    --margin=2 \
    --output="${CLIENT_DIR}/${CLIENT_NAME}_wg.png" \
    < "${CLIENT_DIR}/${CLIENT_NAME}_wg.conf" 2>/dev/null || true

chmod 600 "${CLIENT_DIR}/${CLIENT_NAME}_wg.png" 2>/dev/null || true

# ASCII QR — печатаем в терминал для мгновенного сканирования телефоном
echo ""
echo "[MANAGE] ── QR-код для импорта в AmneziaVPN (AWG) ──────────────"
qrencode \
    --type=ANSIUTF8 \
    --margin=1 \
    < "${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo "[MANAGE] ────────────────────────────────────────────────────────"
echo ""
echo "[MANAGE] ── QR-код для NekoBox / WireGuard (без обфускации) ─────"
qrencode \
    --type=ANSIUTF8 \
    --margin=1 \
    < "${CLIENT_DIR}/${CLIENT_NAME}_wg.conf"
echo "[MANAGE] ────────────────────────────────────────────────────────"
echo ""

# ── Итоговая сводка ───────────────────────────────────────────────────────────
log "=================================================="
log "  Клиент '${CLIENT_NAME}' успешно добавлен!"
log "  IP в туннеле : ${CLIENT_TUNNEL_IP}"
log "  Конфиг AWG   : ${CLIENT_DIR}/${CLIENT_NAME}.conf"
log "  Конфиг WG    : ${CLIENT_DIR}/${CLIENT_NAME}_wg.conf  (для NekoBox)"
log "  QR PNG (AWG) : ${CLIENT_DIR}/${CLIENT_NAME}.png"
log "  QR PNG (WG)  : ${CLIENT_DIR}/${CLIENT_NAME}_wg.png   (для NekoBox)"
log "  Ключи        : ${CLIENT_KEYS_DIR}/"
log "=================================================="
MANAGE_SCRIPT_EOF
# ── manage.sh заканчивается здесь ────────────────────────────────────────────

chmod +x "${VPN_DIR}/manage.sh"
log "manage.sh создан и сделан исполняемым."

# ==============================================================================
# 15. Создаём файл-флаг успешной установки
# ==============================================================================
touch "${VPN_DIR}/.deployed"

log "=================================================="
log "  УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
log ""
log "  Директория: ${VPN_DIR}"
log "  Порт:       ${WG_PORT}/udp"
log "  Публичный IP: ${PUBLIC_IP}"
log ""
log "  Для добавления клиента:"
log "  bash ${VPN_DIR}/manage.sh <имя_клиента>"
log "=================================================="
