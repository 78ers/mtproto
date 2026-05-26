#!/bin/bash
# =====================================================================
# MTProto Proxy Manager
# Установка и управление личным MTProto-прокси для Telegram на базе mtg
# Репозиторий: https://github.com/78ers/mtproto
# =====================================================================

set -Eeuo pipefail

# ===== КОНСТАНТЫ =====
MTG_DIR="/etc/mtg"
CLIENTS_DIR="${MTG_DIR}/clients"
MTG_BIN="/usr/local/bin/mtg"
SCRIPT_TARGET="/usr/local/bin/tgproxy"
SERVICE_TEMPLATE="/etc/systemd/system/mtg@.service"
PORT_MIN=8443
PORT_MAX=8500
MTG_USER="mtg"
MTG_GROUP="mtg"
DEFAULT_FAKE_TLS_DOMAIN="www.google.com"
MTG_REPO="9seconds/mtg"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ===== ВСПОМОГАТЕЛЬНЫЕ =====
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
pause(){ read -rp "Enter для возврата..." _; }

check_root() {
    [[ $EUID -eq 0 ]] || { err "Запустите от root (sudo bash $0)"; exit 1; }
}

# Получить публичный IPv4 сервера (без сторонних сервисов, fallback на ipify)
get_server_ip() {
    local iface ip
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "$iface" ]]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null \
             | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi
    if [[ -z "${ip:-}" ]]; then
        ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    echo "${ip:-0.0.0.0}"
}

# Поиск свободного порта в диапазоне
find_free_port() {
    local p used
    for ((p=PORT_MIN; p<=PORT_MAX; p++)); do
        used=0
        # Уже используется системой?
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
            used=1
        fi
        # Уже занят другим клиентом?
        if [[ -d "$CLIENTS_DIR" ]]; then
            if grep -lqE "^bind-to\s*=\s*\"[^\"]*:${p}\"" "$CLIENTS_DIR"/*.toml 2>/dev/null; then
                used=1
            fi
        fi
        if [[ $used -eq 0 ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Валидаторы
valid_name()   { [[ "$1" =~ ^[a-z0-9_-]{1,20}$ ]]; }
valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
# Fake-TLS секрет: ee + 32 hex (16 байт random) + hex домена (минимум 2 hex)
valid_secret() { [[ "$1" =~ ^ee[0-9a-f]{34,}$ ]] && (( ${#1} % 2 == 0 )); }

# Извлечь домен из Fake-TLS секрета (последние байты после ee + 32 hex)
domain_from_secret() {
    local secret="$1"
    local domain_hex="${secret:34}"
    echo -n "$domain_hex" | xxd -r -p 2>/dev/null
}

# Чтение значений из toml клиента (примитивный парсер для двух известных ключей)
get_secret() { grep -E '^secret\s*=' "$1" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/'; }
get_bind()   { grep -E '^bind-to\s*=' "$1" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/'; }
get_port()   { get_bind "$1" | awk -F: '{print $NF}'; }

# Запись TOML конфига клиента
save_client_toml() {
    local file="$1" secret="$2" port="$3"
    cat > "$file" <<EOF
# Конфиг mtg для клиента (управляется через tgproxy)
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF
    chmod 600 "$file"
    chown "${MTG_USER}:${MTG_GROUP}" "$file"
}

# ===== УСТАНОВКА =====
prepare_system() {
    info "Установка зависимостей (curl, jq, qrencode, xxd)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl wget jq qrencode xxd ca-certificates >/dev/null

    # BBR + IP forwarding (полезно, безопасно)
    if ! grep -qE "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    grep -qE "^net.core.default_qdisc=fq" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -qE "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null

    # Системный пользователь mtg
    if ! id -u "$MTG_USER" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -M -d /nonexistent "$MTG_USER"
    fi

    # Каталоги
    mkdir -p "$MTG_DIR" "$CLIENTS_DIR"
    chown -R "${MTG_USER}:${MTG_GROUP}" "$MTG_DIR"
    chmod 700 "$MTG_DIR" "$CLIENTS_DIR"
}

install_mtg() {
    if [[ -x "$MTG_BIN" ]]; then
        info "mtg уже установлен: $("$MTG_BIN" --version 2>&1 | head -1)"
        return 0
    fi
    info "Поиск последнего релиза mtg..."

    local arch tag asset url tmpdir
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l)        arch="arm-7" ;;
        *) err "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
    esac

    tag=$(curl -fsSL "https://api.github.com/repos/${MTG_REPO}/releases/latest" | jq -r '.tag_name')
    [[ -z "$tag" || "$tag" == "null" ]] && { err "Не удалось получить тег релиза"; exit 1; }

    asset="mtg-${tag#v}-linux-${arch}.tar.gz"
    url="https://github.com/${MTG_REPO}/releases/download/${tag}/${asset}"

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    info "Скачивание ${tag} (${arch})..."
    curl -fsSL "$url" -o "${tmpdir}/mtg.tar.gz"

    # Проверка SHA256 (если есть в релизе)
    local sha_url="https://github.com/${MTG_REPO}/releases/download/${tag}/checksums.txt"
    if curl -fsSL "$sha_url" -o "${tmpdir}/checksums.txt" 2>/dev/null; then
        local expected actual
        expected=$(grep "$asset" "${tmpdir}/checksums.txt" | awk '{print $1}' | head -1)
        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "${tmpdir}/mtg.tar.gz" | awk '{print $1}')
            if [[ "$expected" != "$actual" ]]; then
                err "SHA256 не совпадает! Ожидалось: $expected, получено: $actual"
                exit 1
            fi
            ok "SHA256 проверен"
        fi
    fi

    tar -xzf "${tmpdir}/mtg.tar.gz" -C "$tmpdir"
    local binary
    binary=$(find "$tmpdir" -name mtg -type f -executable | head -1)
    [[ -z "$binary" ]] && { err "Бинарь mtg не найден в архиве"; exit 1; }

    install -m 0755 "$binary" "$MTG_BIN"
    ok "mtg установлен: $("$MTG_BIN" --version 2>&1 | head -1)"
}

install_systemd_template() {
    cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=mtg MTProto proxy (client: %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MTG_BIN} run ${CLIENTS_DIR}/%i.toml
Restart=on-failure
RestartSec=5
User=${MTG_USER}
Group=${MTG_GROUP}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadOnlyPaths=${MTG_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "Systemd template установлен: mtg@<имя>.service"
}

setup_firewall() {
    if ! command -v ufw >/dev/null; then
        info "UFW не установлен — порты для клиентов открывать вручную"
        info "Установить можно: apt install ufw"
        return 0
    fi
    local status
    status=$(ufw status 2>/dev/null | head -1)
    if [[ "$status" == *"inactive"* ]]; then
        warn "UFW установлен, но не активен."
        warn "Можно включить вручную: ufw allow <ssh_port>/tcp && ufw enable"
        warn "(Скрипт не активирует UFW сам, чтобы не оборвать SSH-сессию)"
    else
        ok "UFW активен — открытие портов клиентов будет автоматическим"
    fi
}

install_self() {
    if [[ "$(realpath "$0")" != "$SCRIPT_TARGET" ]]; then
        install -m 0755 "$0" "$SCRIPT_TARGET"
        ok "Команда установлена: tgproxy"
    fi
}

# ===== ОПЕРАЦИИ С КЛИЕНТАМИ =====

list_client_names() {
    local f names=()
    if [[ -d "$CLIENTS_DIR" ]]; then
        for f in "$CLIENTS_DIR"/*.toml; do
            [[ -e "$f" ]] || continue
            names+=("$(basename "$f" .toml)")
        done
    fi
    printf '%s\n' "${names[@]:-}"
}

print_clients_table() {
    local i=1 f name port secret domain state
    printf "  ${BOLD}%-3s %-15s %-6s %-10s %s${NC}\n" "№" "ИМЯ" "ПОРТ" "СТАТУС" "FAKE-TLS"
    printf "  %s\n" "──────────────────────────────────────────────────────"
    for f in "$CLIENTS_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .toml)
        port=$(get_port "$f")
        secret=$(get_secret "$f")
        domain=$(domain_from_secret "$secret")
        if systemctl is-active --quiet "mtg@${name}.service"; then
            state="${GREEN}● up${NC}  "
        else
            state="${RED}○ down${NC}"
        fi
        printf "  %-3s %-15s %-6s %b %s\n" "$i" "$name" "$port" "$state" "$domain"
        ((i++))
    done
}

# Сгенерировать новый секрет через mtg
gen_secret() {
    local domain="$1"
    "$MTG_BIN" generate-secret --hex "$domain"
}

# Открыть порт в UFW (если активен)
ufw_allow() {
    local port="$1"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
}

ufw_delete() {
    local port="$1"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
}

# Запросить источник секрета и вернуть пару "secret|domain"
prompt_secret_source() {
    local default_domain="${1:-$DEFAULT_FAKE_TLS_DOMAIN}"
    local src secret domain
    echo "Источник секрета:" >&2
    echo "  1) Сгенерировать (Fake-TLS домен: ${default_domain})" >&2
    echo "  2) Сгенерировать с другим Fake-TLS доменом" >&2
    echo "  3) Ввести готовый секрет (ee...hex)" >&2
    read -rp "Выбор [1]: " src
    src=${src:-1}
    case "$src" in
        1)
            domain="$default_domain"
            secret=$(gen_secret "$domain")
            ;;
        2)
            while true; do
                read -rp "Fake-TLS домен: " domain
                valid_domain "$domain" && break
                err "Некорректный домен" >&2
            done
            secret=$(gen_secret "$domain")
            ;;
        3)
            while true; do
                read -rp "Секрет (ee...hex): " secret
                if valid_secret "$secret"; then
                    domain=$(domain_from_secret "$secret")
                    info "Извлечён домен: ${domain}" >&2
                    break
                fi
                err "Некорректный формат секрета" >&2
            done
            ;;
        *)
            return 1
            ;;
    esac
    echo "${secret}|${domain}"
}

add_client() {
    clear
    echo -e "${BOLD}=== Добавить клиента ===${NC}\n"

    local name
    while true; do
        read -rp "Имя клиента (a-z, 0-9, _-, до 20): " name
        if ! valid_name "$name"; then err "Недопустимое имя"; continue; fi
        if [[ -f "${CLIENTS_DIR}/${name}.toml" ]]; then err "Клиент уже существует"; continue; fi
        break
    done

    local port
    if ! port=$(find_free_port); then
        err "Нет свободных портов в диапазоне ${PORT_MIN}-${PORT_MAX}"
        pause; return
    fi
    info "Назначен свободный порт: ${port}"

    local pair secret domain
    pair=$(prompt_secret_source "$DEFAULT_FAKE_TLS_DOMAIN") || { warn "Отмена"; pause; return; }
    secret="${pair%|*}"
    domain="${pair#*|}"

    save_client_toml "${CLIENTS_DIR}/${name}.toml" "$secret" "$port"
    ufw_allow "$port"
    systemctl enable --now "mtg@${name}.service" >/dev/null 2>&1

    sleep 1
    if systemctl is-active --quiet "mtg@${name}.service"; then
        ok "Клиент '${name}' создан и запущен"
        echo
        show_client_link "$name"
    else
        err "Сервис не стартовал. Логи: journalctl -u mtg@${name} -n 30"
        pause
    fi
}

show_client_link() {
    local name="$1"
    local file="${CLIENTS_DIR}/${name}.toml"
    [[ -f "$file" ]] || { err "Клиент не найден"; pause; return; }

    local port secret domain ip link link_https
    port=$(get_port "$file")
    secret=$(get_secret "$file")
    domain=$(domain_from_secret "$secret")
    ip=$(get_server_ip)

    link="tg://proxy?server=${ip}&port=${port}&secret=${secret}"
    link_https="https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}"

    clear
    echo -e "${BOLD}${MAGENTA}═══ Клиент: ${name} ═══${NC}\n"
    echo -e "${CYAN}Сервер:${NC}   ${ip}"
    echo -e "${CYAN}Порт:${NC}     ${port}"
    echo -e "${CYAN}Fake-TLS:${NC} ${domain}"
    echo -e "${CYAN}Секрет:${NC}   ${secret}"
    echo
    echo -e "${YELLOW}tg:// ссылка (вставить в Telegram → Настройки → Прокси):${NC}"
    echo -e "  ${GREEN}${link}${NC}"
    echo
    echo -e "${YELLOW}HTTPS-ссылка (открыть в браузере на телефоне):${NC}"
    echo -e "  ${GREEN}${link_https}${NC}"
    echo
    echo -e "${YELLOW}QR-код (отсканировать с телефона):${NC}"
    qrencode -t ANSIUTF8 "$link" -m 1
    echo
    pause
}

rename_client() {
    local old="$1" new
    while true; do
        read -rp "Новое имя для '${old}': " new
        if ! valid_name "$new"; then err "Недопустимое имя"; continue; fi
        if [[ "$new" == "$old" ]]; then warn "Имя не изменилось"; return; fi
        if [[ -f "${CLIENTS_DIR}/${new}.toml" ]]; then err "Имя уже занято"; continue; fi
        break
    done
    systemctl disable --now "mtg@${old}.service" >/dev/null 2>&1
    mv "${CLIENTS_DIR}/${old}.toml" "${CLIENTS_DIR}/${new}.toml"
    systemctl enable --now "mtg@${new}.service" >/dev/null 2>&1
    ok "Переименован: ${old} → ${new}"
    pause
}

change_secret() {
    local name="$1"
    local file="${CLIENTS_DIR}/${name}.toml"
    local port cur_secret cur_domain
    port=$(get_port "$file")
    cur_secret=$(get_secret "$file")
    cur_domain=$(domain_from_secret "$cur_secret")

    echo
    warn "Старые tg://proxy ссылки этого клиента перестанут работать!"
    echo

    local pair secret domain
    pair=$(prompt_secret_source "$cur_domain") || { warn "Отмена"; pause; return; }
    secret="${pair%|*}"
    domain="${pair#*|}"

    read -rp "Применить изменения? (y/n): " yn
    [[ "$yn" != "y" ]] && { info "Отмена"; pause; return; }

    save_client_toml "$file" "$secret" "$port"
    systemctl restart "mtg@${name}.service"
    ok "Секрет обновлён, сервис перезапущен"
    pause
}

delete_client() {
    local name="$1"
    local file="${CLIENTS_DIR}/${name}.toml"
    read -rp "Удалить клиента '${name}'? (y/n): " yn
    [[ "$yn" != "y" ]] && { info "Отмена"; pause; return; }
    local port; port=$(get_port "$file")
    systemctl disable --now "mtg@${name}.service" >/dev/null 2>&1
    ufw_delete "$port"
    rm -f "$file"
    ok "Клиент '${name}' удалён"
    pause
}

client_logs() {
    local name="$1"
    clear
    echo -e "${BOLD}═══ Логи: mtg@${name} (последние 50 строк) ═══${NC}\n"
    journalctl -u "mtg@${name}.service" -n 50 --no-pager 2>&1 || true
    echo
    pause
}

# ===== СЛУЖБА =====
restart_all_mtg() {
    local names=()
    mapfile -t names < <(list_client_names)
    if [[ -z "${names[0]:-}" ]]; then warn "Клиентов нет"; pause; return; fi
    local n cnt=0
    for n in "${names[@]}"; do
        [[ -z "$n" ]] && continue
        systemctl restart "mtg@${n}.service"
        ((cnt++))
    done
    ok "Перезапущено клиентов: ${cnt}"
    pause
}

reboot_vps() {
    echo -e "${RED}${BOLD}ВНИМАНИЕ:${NC} полная перезагрузка VPS"
    read -rp "Введите YES для подтверждения: " confirm
    if [[ "$confirm" == "YES" ]]; then
        info "Перезагрузка через 3 секунды..."
        sleep 3
        reboot
    else
        info "Отмена"
        pause
    fi
}

update_mtg() {
    info "Проверка последнего релиза..."
    local tag cur
    tag=$(curl -fsSL "https://api.github.com/repos/${MTG_REPO}/releases/latest" | jq -r '.tag_name')
    cur=$("$MTG_BIN" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    cur="v${cur#v}"

    info "Текущая версия: ${cur}"
    info "Последняя:      ${tag}"
    if [[ "$cur" == "$tag" ]]; then
        ok "Уже последняя версия"
        pause; return
    fi
    read -rp "Обновить? (y/n): " yn
    [[ "$yn" != "y" ]] && { info "Отмена"; pause; return; }

    rm -f "$MTG_BIN"
    install_mtg

    info "Перезапуск всех клиентов..."
    local names=() n
    mapfile -t names < <(list_client_names)
    for n in "${names[@]}"; do
        [[ -z "$n" ]] && continue
        systemctl restart "mtg@${n}.service"
    done
    ok "Обновление завершено"
    pause
}

uninstall_all() {
    clear
    echo -e "${RED}${BOLD}═══ ПОЛНОЕ УДАЛЕНИЕ ═══${NC}"
    echo "Будет удалено:"
    echo "  - все клиенты и их конфиги"
    echo "  - бинарь mtg"
    echo "  - systemd template mtg@.service"
    echo "  - команда tgproxy"
    echo "  - пользователь mtg"
    echo
    read -rp "Введите YES для подтверждения: " yn
    [[ "$yn" != "YES" ]] && { info "Отмена"; pause; return; }

    local names=() n port
    mapfile -t names < <(list_client_names)
    for n in "${names[@]}"; do
        [[ -z "$n" ]] && continue
        port=$(get_port "${CLIENTS_DIR}/${n}.toml" 2>/dev/null || true)
        systemctl disable --now "mtg@${n}.service" >/dev/null 2>&1 || true
        [[ -n "$port" ]] && ufw_delete "$port"
    done

    rm -f "$SERVICE_TEMPLATE"
    systemctl daemon-reload
    rm -rf "$MTG_DIR"
    rm -f "$MTG_BIN" "$SCRIPT_TARGET"
    userdel "$MTG_USER" 2>/dev/null || true

    ok "Удаление завершено. Перезапустите терминал."
    exit 0
}

# ===== МЕНЮ =====

client_action_menu() {
    local name="$1"
    while true; do
        clear
        echo -e "${BOLD}${MAGENTA}═══ Клиент: ${name} ═══${NC}\n"
        echo "  1) Показать ссылку + QR"
        echo "  2) Переименовать"
        echo "  3) Сменить секрет"
        echo "  4) Удалить"
        echo "  5) Логи (последние 50 строк)"
        echo "  0) Назад"
        echo
        read -rp "Выбор: " ch
        case "$ch" in
            1) show_client_link "$name" ;;
            2) rename_client "$name"; return ;;
            3) change_secret "$name" ;;
            4) delete_client "$name"; return ;;
            5) client_logs "$name" ;;
            0) return ;;
            *) ;;
        esac
    done
}

clients_menu() {
    while true; do
        clear
        echo -e "${BOLD}═══ УПРАВЛЕНИЕ КЛИЕНТАМИ ═══${NC}\n"
        local names=()
        mapfile -t names < <(list_client_names)
        if [[ -z "${names[0]:-}" ]]; then
            warn "Клиентов пока нет. Создай первого из главного меню."
            echo
            pause
            return
        fi
        print_clients_table
        echo
        read -rp "Номер клиента (0 — назад): " idx
        [[ "$idx" == "0" ]] && return
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#names[@]} )); then
            err "Неверный номер"; sleep 1; continue
        fi
        client_action_menu "${names[$((idx-1))]}"
    done
}

service_menu() {
    while true; do
        clear
        echo -e "${BOLD}═══ СЛУЖБА ═══${NC}\n"
        echo "  1) Перезапустить mtg (все клиенты)"
        echo "  2) Перезагрузить VPS"
        echo "  3) Обновить mtg"
        echo "  4) Полное удаление"
        echo "  0) Назад"
        echo
        read -rp "Выбор: " ch
        case "$ch" in
            1) restart_all_mtg ;;
            2) reboot_vps ;;
            3) update_mtg ;;
            4) uninstall_all ;;
            0) return ;;
            *) ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║      MTProto Proxy Manager (mtg)         ║"
        echo "  ║      github.com/78ers/mtproto            ║"
        echo "  ╚══════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  1) Добавить клиента"
        echo "  2) Управление клиентами"
        echo "  3) Служба"
        echo "  0) Выход"
        echo
        read -rp "Выбор: " ch
        case "$ch" in
            1) add_client ;;
            2) clients_menu ;;
            3) service_menu ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# ===== ВХОДНАЯ ТОЧКА =====
check_root

# Первый запуск (не из /usr/local/bin/tgproxy) — установка
if [[ "$(realpath "$0")" != "$SCRIPT_TARGET" ]]; then
    info "Первая установка..."
    prepare_system
    install_mtg
    install_systemd_template
    setup_firewall
    install_self
    ok "Установка завершена. В дальнейшем запускайте: tgproxy"
    echo
    # Флаг --install: только установка, без запуска меню (для автоматизации)
    [[ "${1:-}" == "--install" ]] && exit 0
fi

main_menu
