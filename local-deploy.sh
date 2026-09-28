#!/usr/bin/env bash
# ==============================================================================
# local-deploy.sh — Локальный скрипт автоматического развёртывания AmneziaWG VPN
# Запускается на машине КЛИЕНТА (не на сервере)
# ==============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Цветовые коды для красивого вывода в консоль
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}  ℹ ${NC} $*"; }
success() { echo -e "${GREEN}  ✔ ${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠ ${NC} $*"; }
error()   { echo -e "${RED}  ✘ ${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${MAGENTA}▶ $*${NC}"; }

header() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}   ${BOLD}$*${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Спиннер — визуальный индикатор прогресса для длительных операций
# ──────────────────────────────────────────────────────────────────────────────
SPINNER_PID=""

spinner_start() {
    local msg="${1:-Выполняется...}"
    local frames=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}${frames[$((i % 8))]}${NC}  ${DIM}${msg}${NC}   "
            sleep 0.1
            ((i++)) || true
        done
    ) &
    SPINNER_PID=$!
    disown "${SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
    if [[ -n "${SPINNER_PID}" ]]; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%-70s\r" " "
    fi
}

trap 'spinner_stop; echo ""' EXIT INT TERM

# ──────────────────────────────────────────────────────────────────────────────
# SSH/SCP обёртки с передачей пароля через sshpass
# ──────────────────────────────────────────────────────────────────────────────
remote_exec() {
    SSHPASS="${VPS_PASS}" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=30 \
        -o LogLevel=ERROR \
        "${VPS_USER}@${VPS_IP}" "$@"
}

remote_exec_output() {
    SSHPASS="${VPS_PASS}" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        "${VPS_USER}@${VPS_IP}" "$@" 2>&1
}

remote_scp_get() {
    SSHPASS="${VPS_PASS}" sshpass -e scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${VPS_USER}@${VPS_IP}:$1" "$2"
}

remote_scp_put() {
    SSHPASS="${VPS_PASS}" sshpass -e scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$1" "${VPS_USER}@${VPS_IP}:$2"
}

# ──────────────────────────────────────────────────────────────────────────────
# Управление сохранёнными настройками подключения
# Данные хранятся в скрытом файле .vpn-config рядом со скриптом.
# Файл защищён правами 600 (читает только владелец).
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.vpn-config"

# Сохраняет настройки в файл после УСПЕШНОГО подключения
save_config() {
    cat > "${CONFIG_FILE}" << CFG_EOF
# AmneziaWG — сохранённые настройки подключения
# Файл создан: $(date '+%Y-%m-%d %H:%M:%S')
# ВНИМАНИЕ: содержит пароль — никому не передавайте этот файл!
VPS_IP="${VPS_IP}"
VPS_USER="${VPS_USER}"
VPS_PASS="${VPS_PASS}"
CFG_EOF
    # Разрешаем читать файл только текущему пользователю
    chmod 600 "${CONFIG_FILE}"
    success "Настройки сохранены в ${CONFIG_FILE}"
}

# Загружает настройки из файла
load_config() {
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
}

# Полностью удаляет файл с настройками
forget_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        rm -f "${CONFIG_FILE}"
        success "Сохранённые настройки удалены."
    else
        warn "Файл настроек не найден — нечего удалять."
    fi
}

# ==============================================================================
# ЗАГОЛОВОК
# ==============================================================================
clear
echo ""
echo -e "${BOLD}${BLUE}    █████╗ ███╗   ███╗███╗   ██╗███████╗███████╗██╗ █████╗ ${NC}"
echo -e "${BOLD}${BLUE}   ██╔══██╗████╗ ████║████╗  ██║██╔════╝╚════██║██║██╔══██╗${NC}"
echo -e "${BOLD}${BLUE}   ███████║██╔████╔██║██╔██╗ ██║█████╗      ██╔╝██║███████║${NC}"
echo -e "${BOLD}${BLUE}   ██╔══██║██║╚██╔╝██║██║╚██╗██║██╔══╝     ██╔╝ ██║██╔══██║${NC}"
echo -e "${BOLD}${BLUE}   ██║  ██║██║ ╚═╝ ██║██║ ╚████║███████╗   ██║  ██║██║  ██║${NC}"
echo -e "${BOLD}${BLUE}   ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝  ╚═╝╚═╝  ╚═╝${NC}"
echo ""
echo -e "${DIM}              AmneziaWG VPN — Автоматическое развёртывание${NC}"
echo ""

# ==============================================================================
# ШАГ 0: Проверяем зависимости на локальной машине
# ==============================================================================
header "Шаг 0: Проверка зависимостей"

# Проверяем sshpass — нужен для SSH без интерактивного ввода пароля
if ! command -v sshpass &>/dev/null; then
    warn "sshpass не найден — устанавливаем..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y sshpass -qq
    elif command -v yum &>/dev/null; then
        sudo yum install -y sshpass -q
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm sshpass
    elif command -v brew &>/dev/null; then
        brew install hudochenkov/sshpass/sshpass
    else
        error "Не удалось автоматически установить sshpass."
        error "Установите вручную и повторите запуск."
        exit 1
    fi
    success "sshpass установлен."
else
    success "sshpass найден: $(command -v sshpass)"
fi

# Проверяем наличие скрипта установки рядом с локальным скриптом
if [[ ! -f "${SCRIPT_DIR}/remote-setup.sh" ]]; then
    error "Файл remote-setup.sh не найден в директории: ${SCRIPT_DIR}"
    error "Оба скрипта (local-deploy.sh и remote-setup.sh) должны лежать рядом."
    exit 1
fi
success "remote-setup.sh найден."

# ==============================================================================
# ШАГ 1: Данные подключения к VPS
#   Логика:
#   а) Если сохранённые настройки найдены — показываем меню выбора
#   б) Если нет — запрашиваем вручную
# ==============================================================================
header "Шаг 1: Данные подключения к VPS"

VPS_IP=""
VPS_USER=""
VPS_PASS=""

if [[ -f "${CONFIG_FILE}" ]]; then
    # ── Найдены сохранённые настройки ─────────────────────────────────────────
    # Читаем их для отображения (пароль маскируем)
    load_config
    SAVED_IP="${VPS_IP}"
    SAVED_USER="${VPS_USER}"
    PASS_LEN=${#VPS_PASS}
    # Маска пароля: первый символ + звёздочки + последний символ
    if [[ ${PASS_LEN} -le 2 ]]; then
        MASKED_PASS="****"
    else
        MASKED_PASS="${VPS_PASS:0:1}$(printf '*%.0s' $(seq 1 $(( PASS_LEN - 2 ))))${VPS_PASS: -1}"
    fi

    echo -e "  ${GREEN}Найдены сохранённые настройки:${NC}"
    echo ""
    echo -e "  ${DIM}┌─────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC}  IP-адрес : ${BOLD}${SAVED_IP}${NC}"
    echo -e "  ${DIM}│${NC}  Логин    : ${BOLD}${SAVED_USER}${NC}"
    echo -e "  ${DIM}│${NC}  Пароль   : ${BOLD}${MASKED_PASS}${NC}"
    echo -e "  ${DIM}└─────────────────────────────────┘${NC}"
    echo ""
    echo -e "  Выберите действие:"
    echo -e "  ${BOLD}[1]${NC} Использовать сохранённые настройки"
    echo -e "  ${BOLD}[2]${NC} Ввести новые данные вручную"
    echo -e "  ${BOLD}[3]${NC} ${RED}Удалить сохранённые настройки и выйти${NC}"
    echo ""

    while true; do
        read -rp "$(echo -e "  ${BOLD}Ваш выбор [1/2/3]:${NC} ")" CHOICE
        case "${CHOICE}" in
            1)
                # Используем загруженные данные — они уже в VPS_IP/VPS_USER/VPS_PASS
                info "Используем сохранённые настройки для ${SAVED_USER}@${SAVED_IP}"
                break
                ;;
            2)
                # Сбрасываем загруженные данные и запросим вручную ниже
                VPS_IP=""
                VPS_USER=""
                VPS_PASS=""
                break
                ;;
            3)
                # Удаляем файл и завершаем работу
                forget_config
                echo ""
                info "Выход. При следующем запуске данные будут запрошены заново."
                # Сбрасываем trap, чтобы не печатать лишний перенос строки
                trap - EXIT
                exit 0
                ;;
            *)
                warn "Введите 1, 2 или 3."
                ;;
        esac
    done
fi

# Если данные не были загружены из файла (первый запуск или выбран ввод вручную)
if [[ -z "${VPS_IP}" ]]; then
    echo ""
    read -rp "$(echo -e "  ${BOLD}IP-адрес VPS:${NC} ")" VPS_IP
    read -rp "$(echo -e "  ${BOLD}Логин SSH ${DIM}[root]${NC}${BOLD}:${NC} ")" VPS_USER
    VPS_USER="${VPS_USER:-root}"
    read -rsp "$(echo -e "  ${BOLD}Пароль SSH:${NC} ")" VPS_PASS
    echo ""
fi

echo ""

# Базовая валидация введённых данных
[[ -z "${VPS_IP}" ]]   && { error "IP-адрес не может быть пустым."; exit 1; }
[[ -z "${VPS_PASS}" ]] && { error "Пароль не может быть пустым."; exit 1; }

# ── Проверяем подключение к серверу ───────────────────────────────────────────
spinner_start "Проверяем подключение к ${VPS_USER}@${VPS_IP}..."
SSH_OK=false
if SSHPASS="${VPS_PASS}" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        "${VPS_USER}@${VPS_IP}" "echo connected" &>/dev/null; then
    SSH_OK=true
fi
spinner_stop

if [[ "${SSH_OK}" == "false" ]]; then
    error "Не удалось подключиться к серверу!"
    error "Проверьте IP-адрес, логин, пароль и доступность порта 22."
    # Если данные были из файла — предлагаем их удалить
    if [[ -f "${CONFIG_FILE}" ]]; then
        echo ""
        warn "Сохранённые настройки не сработали."
        read -rp "$(echo -e "  ${BOLD}Удалить сохранённые настройки? [y/N]:${NC} ")" DEL_CONFIRM
        if [[ "${DEL_CONFIRM,,}" == "y" ]]; then
            forget_config
        fi
    fi
    exit 1
fi

success "Подключение к ${VPS_USER}@${VPS_IP} успешно."

# ── Сохраняем настройки (только после успешного подключения) ──────────────────
# Если файла ещё нет, или пользователь выбрал «ввести вручную» — спрашиваем
NEED_SAVE=false
if [[ ! -f "${CONFIG_FILE}" ]]; then
    # Файл отсутствовал — это первый успешный вход, предлагаем сохранить
    NEED_SAVE=true
else
    # Файл был, но данные могли быть изменены (выбор «2 — ввести вручную»)
    # Сравниваем текущий IP с сохранённым
    PREV_IP=$(grep '^VPS_IP=' "${CONFIG_FILE}" | cut -d'"' -f2 || echo "")
    [[ "${PREV_IP}" != "${VPS_IP}" ]] && NEED_SAVE=true
fi

if [[ "${NEED_SAVE}" == "true" ]]; then
    echo ""
    read -rp "$(echo -e "  ${BOLD}Сохранить настройки подключения для следующих запусков? [Y/n]:${NC} ")" SAVE_CONFIRM
    if [[ "${SAVE_CONFIRM,,}" != "n" ]]; then
        save_config
        echo -e "  ${DIM}Файл: ${CONFIG_FILE} (права 600, доступен только вам)${NC}"
    else
        info "Настройки НЕ сохранены."
    fi
fi

# ==============================================================================
# ШАГ 2: Проверяем — развёрнуто ли уже ядро VPN
# ==============================================================================
header "Шаг 2: Проверка состояния VPN-ядра"

DEPLOYED=false
if remote_exec "test -f /opt/my-vpn/.deployed" &>/dev/null; then
    DEPLOYED=true
fi

# ==============================================================================
# ШАГ 3: Установка (только если ядро ещё не развёрнуто)
# ==============================================================================
if [[ "${DEPLOYED}" == "false" ]]; then
    step "VPN-ядро не обнаружено — запускаем установку"

    spinner_start "Копируем remote-setup.sh на сервер..."
    remote_scp_put "${SCRIPT_DIR}/remote-setup.sh" "/tmp/remote-setup.sh"
    spinner_stop
    success "Скрипт скопирован на сервер."

    # Установка занимает несколько минут: обновление ОС + Docker + сборка образа AWG
    spinner_start "Устанавливаем Docker и AmneziaWG на сервере (3-7 мин, подождите)..."
    SETUP_OUTPUT=$(remote_exec_output "bash /tmp/remote-setup.sh") || {
        spinner_stop
        error "Установка завершилась с ошибкой!"
        echo ""
        echo -e "${DIM}──── Последние строки вывода сервера ────${NC}"
        echo "${SETUP_OUTPUT}" | tail -30
        echo -e "${DIM}─────────────────────────────────────────${NC}"
        exit 1
    }
    spinner_stop

    # Проверяем файл-флаг успешной установки
    if ! remote_exec "test -f /opt/my-vpn/.deployed" &>/dev/null; then
        error "Установка завершена, но файл-флаг /opt/my-vpn/.deployed не найден!"
        echo -e "${DIM}Вывод сервера:${NC}"
        echo "${SETUP_OUTPUT}" | tail -20
        exit 1
    fi

    success "VPN-ядро успешно развёрнуто на сервере!"

else
    success "VPN-ядро уже развёрнуто. Пропускаем установку."
fi

# ==============================================================================
# ШАГ 2.5: Копируем remote-setup.sh на сервер (один раз — используется в 2.5 и 3.5)
# ==============================================================================
spinner_start "Копируем remote-setup.sh на сервер..."
remote_scp_put "${SCRIPT_DIR}/remote-setup.sh" "/tmp/remote-setup.sh"
spinner_stop
success "remote-setup.sh скопирован."

# ==============================================================================
# ШАГ 2.5: Проверка готовности сервера
#   Проверяет и при необходимости исправляет:
#   - Модуль ядра amneziawg (собирает если нет)
#   - Docker-контейнер (запускает если не работает)
#   - Интерфейс wg0 (перезапускает контейнер если не поднят)
#   - Порт UDP 51820 (проверяет что слушается)
# ==============================================================================
header "Шаг 2.5: Проверка готовности сервера"

info "Проверяем модуль ядра, контейнер, интерфейс wg0, порт 51820..."
echo ""

SETUP_OUTPUT=$(remote_exec_output "bash /tmp/remote-setup.sh --setup-kernel") ; SETUP_EXIT=$?

# Выводим результаты проверки
echo "${SETUP_OUTPUT}" | grep -E '(✔|✘|WARN|ERROR)' | while IFS= read -r line; do
    if echo "${line}" | grep -q '✔'; then
        echo -e "  ${GREEN}${line}${NC}"
    else
        echo -e "  ${YELLOW}${line}${NC}"
    fi
done
echo ""

if [[ ${SETUP_EXIT} -ne 0 ]]; then
    error "Сервер не готов принимать VPN-подключения!"
    echo ""
    echo -e "${DIM}──── Вывод диагностики ────${NC}"
    echo "${SETUP_OUTPUT}" | tail -20
    echo -e "${DIM}───────────────────────────${NC}"
    echo ""
    read -rp "$(echo -e "  ${BOLD}Продолжить несмотря на ошибки? [y/N]:${NC} ")" CONT
    [[ "${CONT,,}" != "y" ]] && exit 1
else
    success "Сервер готов принимать VPN-подключения!"
fi

# ==============================================================================
# ШАГ 3.5: Обновляем manage.sh на сервере (при каждом запуске)
#   remote-setup.sh уже скопирован в шаге 2.5
# ==============================================================================
header "Шаг 3.5: Обновление manage.sh на сервере"

spinner_start "Обновляем manage.sh..."
UPDATE_OUTPUT=$(remote_exec_output "bash /tmp/remote-setup.sh --update-manage") || {
    spinner_stop
    warn "Не удалось обновить manage.sh (продолжаем — используется старая версия)."
    echo -e "${DIM}Вывод сервера:${NC}"
    echo "${UPDATE_OUTPUT}" | tail -10
}
spinner_stop
success "manage.sh обновлён."

# ==============================================================================
# ШАГ 4: Запрашиваем имя нового VPN-клиента
# ==============================================================================
header "Шаг 4: Создание нового VPN-клиента"

echo -e "  ${DIM}Имя используется для файла конфига. Только буквы, цифры, _.${NC}"
echo ""
read -rp "$(echo -e "  ${BOLD}Имя клиента (напр. ivan_phone):${NC} ")" CLIENT_NAME

# Нормализуем имя: пробелы и дефисы → подчёркивание, убираем спецсимволы
CLIENT_NAME=$(echo "${CLIENT_NAME}" | tr ' -' '__' | tr -cd '[:alnum:]_')

[[ -z "${CLIENT_NAME}" ]] && { error "Имя клиента не может быть пустым."; exit 1; }
info "Имя клиента: ${BOLD}${CLIENT_NAME}${NC}"

# ==============================================================================
# ШАГ 5: Генерируем конфигурацию клиента на сервере
# ==============================================================================
step "Генерируем конфигурацию для '${CLIENT_NAME}'"

spinner_start "Генерируем ключи, обфускацию и список IP-адресов..."
GEN_OUTPUT=$(remote_exec_output "bash /opt/my-vpn/manage.sh '${CLIENT_NAME}'") || {
    spinner_stop
    error "Ошибка при генерации конфигурации!"
    echo ""
    echo -e "${DIM}Вывод сервера:${NC}"
    echo "${GEN_OUTPUT}"
    exit 1
}
spinner_stop
success "Конфигурация для '${CLIENT_NAME}' сгенерирована."

# ==============================================================================
# ШАГ 6: Скачиваем .conf файл на локальную машину
# ==============================================================================
header "Шаг 6: Скачивание конфигурации и QR-кода"

LOCAL_CONF="${SCRIPT_DIR}/${CLIENT_NAME}.conf"
LOCAL_QR="${SCRIPT_DIR}/${CLIENT_NAME}.png"

# Скачиваем .conf файл
spinner_start "Скачиваем ${CLIENT_NAME}.conf..."
if ! remote_scp_get "/opt/my-vpn/clients/${CLIENT_NAME}.conf" "${LOCAL_CONF}"; then
    spinner_stop
    error "Не удалось скачать конфигурационный файл с сервера."
    exit 1
fi
spinner_stop
success "Конфигурация скачана: ${LOCAL_CONF}"

# ──────────────────────────────────────────────────────────────────────────────
# Скачиваем директорию keys/ клиента с сервера
# ──────────────────────────────────────────────────────────────────────────────
LOCAL_KEYS_DIR="${SCRIPT_DIR}/keys/${CLIENT_NAME}"
mkdir -p "${LOCAL_KEYS_DIR}"

spinner_start "Скачиваем ключи клиента keys/${CLIENT_NAME}/..."
KEYS_OK=true
for KEY_FILE in private.key public.key preshared.key info.txt; do
    if ! remote_scp_get "/opt/my-vpn/keys/${CLIENT_NAME}/${KEY_FILE}" \
                         "${LOCAL_KEYS_DIR}/${KEY_FILE}" 2>/dev/null; then
        KEYS_OK=false
    fi
done
spinner_stop

if [[ "${KEYS_OK}" == "true" ]]; then
    # Защищаем приватный ключ локально
    chmod 600 "${LOCAL_KEYS_DIR}/private.key" "${LOCAL_KEYS_DIR}/preshared.key" 2>/dev/null || true
    success "Ключи сохранены: ${LOCAL_KEYS_DIR}/"
else
    warn "Не удалось скачать все ключи (это не критично, конфиг уже скачан)."
fi

# Скачиваем QR PNG (может отсутствовать на старых инсталляциях — не критично)
spinner_start "Скачиваем ${CLIENT_NAME}.png (QR-код AWG)..."
if remote_scp_get "/opt/my-vpn/clients/${CLIENT_NAME}.png" "${LOCAL_QR}" 2>/dev/null; then
    spinner_stop
    success "QR PNG (AWG) скачан: ${LOCAL_QR}"
else
    spinner_stop
    warn "QR PNG не найден на сервере (это не критично)."
    LOCAL_QR=""
fi

# Скачиваем WireGuard-совместимый конфиг (для NekoBox / SagerNet)
LOCAL_WG_CONF="${SCRIPT_DIR}/${CLIENT_NAME}_wg.conf"
LOCAL_WG_QR="${SCRIPT_DIR}/${CLIENT_NAME}_wg.png"

spinner_start "Скачиваем ${CLIENT_NAME}_wg.conf (для NekoBox)..."
if remote_scp_get "/opt/my-vpn/clients/${CLIENT_NAME}_wg.conf" "${LOCAL_WG_CONF}" 2>/dev/null; then
    spinner_stop
    success "WireGuard конфиг скачан: ${LOCAL_WG_CONF}"
else
    spinner_stop
    warn "WireGuard конфиг (_wg.conf) не найден — возможно старая версия manage.sh на сервере."
    LOCAL_WG_CONF=""
fi

spinner_start "Скачиваем ${CLIENT_NAME}_wg.png (QR для NekoBox)..."
if remote_scp_get "/opt/my-vpn/clients/${CLIENT_NAME}_wg.png" "${LOCAL_WG_QR}" 2>/dev/null; then
    spinner_stop
    success "QR PNG (WG/NekoBox) скачан: ${LOCAL_WG_QR}"
else
    spinner_stop
    LOCAL_WG_QR=""
fi

# Печатаем ASCII QR прямо в терминал, если qrencode установлен локально
if [[ -f "${LOCAL_CONF}" ]]; then
    if command -v qrencode &>/dev/null; then
        echo ""
        echo -e "${BOLD}${CYAN}  ── QR-код для импорта в AmneziaVPN ──────────────────${NC}"
        qrencode --type=ANSIUTF8 --margin=1 < "${LOCAL_CONF}"
        echo -e "${BOLD}${CYAN}  ────────────────────────────────────────────────────${NC}"
    else
        # Пробуем извлечь QR из вывода серверного manage.sh (GEN_OUTPUT)
        QR_LINES=$(echo "${GEN_OUTPUT}" | grep -A 200 'QR-код для импорта' | head -100 2>/dev/null || echo "")
        if [[ -n "${QR_LINES}" ]]; then
            echo ""
            echo -e "${BOLD}${CYAN}  ── QR-код для импорта в AmneziaVPN ──────────────────${NC}"
            echo "${QR_LINES}"
            echo -e "${BOLD}${CYAN}  ────────────────────────────────────────────────────${NC}"
        else
            info "Установите qrencode локально для отображения QR в терминале:"
            info "  Ubuntu/Debian: sudo apt install qrencode"
            info "  macOS:         brew install qrencode"
        fi
    fi
fi

# ==============================================================================
# ФИНАЛ
# ==============================================================================
if [[ -f "${LOCAL_CONF}" ]]; then
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
    echo -e "${BOLD}${GREEN}║   ✔  VPN-клиент успешно создан!                         ║${NC}"
    echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
    echo -e "${BOLD}${GREEN}║   Клиент : ${NC}${BOLD}${CLIENT_NAME}${NC}"
    echo -e "${BOLD}${GREEN}║   Конфиг : ${NC}${LOCAL_CONF}"
    if [[ -n "${LOCAL_QR:-}" && -f "${LOCAL_QR}" ]]; then
    echo -e "${BOLD}${GREEN}║   QR PNG : ${NC}${LOCAL_QR}"
    fi
    if [[ -d "${LOCAL_KEYS_DIR:-}" ]]; then
    echo -e "${BOLD}${GREEN}║   Ключи  : ${NC}${LOCAL_KEYS_DIR}/"
    fi
    if [[ -n "${LOCAL_WG_CONF:-}" && -f "${LOCAL_WG_CONF}" ]]; then
    echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
    echo -e "${BOLD}${GREEN}║   NekoBox / WireGuard (без обфускации):                 ║${NC}"
    echo -e "${BOLD}${GREEN}║   WG конф: ${NC}${LOCAL_WG_CONF}"
    fi
    if [[ -n "${LOCAL_WG_QR:-}" && -f "${LOCAL_WG_QR}" ]]; then
    echo -e "${BOLD}${GREEN}║   WG QR  : ${NC}${LOCAL_WG_QR}"
    fi
    echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
    echo -e "${BOLD}${GREEN}║   Импортируйте .conf или отсканируйте QR в AmneziaVPN   ║${NC}"
    echo -e "${BOLD}${GREEN}║   (iOS / Android / macOS / Windows / Linux)             ║${NC}"
    echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
else
    error "Файл конфигурации не найден локально после скачивания."
    exit 1
fi
