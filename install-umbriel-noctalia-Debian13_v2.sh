#!/usr/bin/env bash
# Debian 13 Trixie: Umbriel + Noctalia + Noctalia Greeter (Wayland).

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="4.1"
NOCTALIA_VERSION_PREFIX="${NOCTALIA_VERSION_PREFIX:-5.4.1}"
ENABLE_GREETER="${ENABLE_GREETER:-}"
GREETER_CHOICE="${GREETER_CHOICE:-auto}"
KEYBOARD_LAYOUTS="${KEYBOARD_LAYOUTS:-us,ru}"
KEYBOARD_MODEL="${KEYBOARD_MODEL:-pc105}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT:-}"
KEYBOARD_OPTIONS="${KEYBOARD_OPTIONS:-grp:alt_shift_toggle}"
CURRENT_DM_UNIT=""

LOG="/var/log/umbriel-noctalia-install.log"
BACKUP="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_SUSPEND=1

APT_OPTS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o DPkg::Lock::Timeout=120
    -o Acquire::Retries=3
)

TMP_DIR=""
UMBRIEL_RUNTIME=""

cleanup() {
    [[ -n "$UMBRIEL_RUNTIME" && -d "$UMBRIEL_RUNTIME" ]] && rm -rf "$UMBRIEL_RUNTIME"
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

detect_graphical_stack() {
    HAS_GRAPHICAL_SHELL=0
    GRAPHICAL_COMPONENTS=()

    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        CURRENT_DM_UNIT="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)")"
        [[ -n "$CURRENT_DM_UNIT" ]] && GRAPHICAL_COMPONENTS+=("display manager: $CURRENT_DM_UNIT")
        HAS_GRAPHICAL_SHELL=1
    fi

    local package
    for package in gdm3 sddm lightdm lxdm; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            GRAPHICAL_COMPONENTS+=("$package")
            HAS_GRAPHICAL_SHELL=1
        fi
    done

    for package in gnome-shell plasma-desktop xfce4-session mate-session cinnamon-session; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            GRAPHICAL_COMPONENTS+=("$package")
            HAS_GRAPHICAL_SHELL=1
        fi
    done
}

choose_greeter() {
    [[ -n "$ENABLE_GREETER" ]] && return 0

    detect_graphical_stack

    if ((HAS_GRAPHICAL_SHELL)); then
        info "Обнаружена существующая графическая среда: ${GRAPHICAL_COMPONENTS[*]}"

        if [[ ! -t 0 || ! -t 1 ]]; then
            warn "Интерактивный выбор недоступен. Сохраняю существующий display manager."
            ENABLE_GREETER=0
            GREETER_CHOICE=keep
            return 0
        fi

        printf '\nУстановить Noctalia Greeter вместо текущего display manager? [y/N]: '
        read -r answer
        case "$answer" in
            y|Y|yes|YES|д|Д|да|ДА)
                ENABLE_GREETER=1
                GREETER_CHOICE=install
                ;;
            *)
                ENABLE_GREETER=0
                GREETER_CHOICE=keep
                info "Текущий display manager будет сохранён."
                ;;
        esac
    else
        ENABLE_GREETER=1
        GREETER_CHOICE=install
        info "Графическая оболочка/display manager не обнаружены. Noctalia Greeter будет установлен."
    fi
}

usage() {
    cat <<'EOF'
Использование:
  sudo ./install-umbriel-noctalia_new.sh [опции]

Опции:
  --no-greeter     Установить Umbriel и Noctalia без Noctalia Greeter.
  --keep-display-manager
                   Сохранить существующий display manager и не устанавливать Greeter.
  --use-noctalia-greeter
                   Установить Noctalia Greeter вместо существующего display manager.
  -h, --help       Показать эту справку.

Переменные окружения:
  ENABLE_GREETER=0        То же, что --no-greeter.
  ENABLE_GREETER=1        Установить Greeter без вопроса.
  GREETER_CHOICE=keep     Сохранить текущий display manager.
  GREETER_CHOICE=install  Установить Noctalia Greeter.
  NOCTALIA_VERSION_PREFIX Ожидаемая версия Noctalia (по умолчанию 5.4.1).
  KEYBOARD_LAYOUTS        Список раскладок (по умолчанию us,ru).
  KEYBOARD_OPTIONS        Опция переключения (по умолчанию grp:alt_shift_toggle).
EOF
}

while (($#)); do
    case "$1" in
        --no-greeter)
            ENABLE_GREETER=0
            GREETER_CHOICE=keep
            ;;
        --keep-display-manager)
            ENABLE_GREETER=0
            GREETER_CHOICE=keep
            ;;
        --use-noctalia-greeter)
            ENABLE_GREETER=1
            GREETER_CHOICE=install
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Неизвестный аргумент: $1 (используй --help)"
            ;;
    esac
    shift
done

run_apt() {
    apt-get "${APT_OPTS[@]}" "$@"
}

apt_update() {
    run_apt update ||
        die "apt-get update завершился с ошибкой. Проверь /etc/apt/sources.list, /etc/apt/sources.list.d и подключение к сети."
}

# apt-cache is localized; force C locale so "Candidate:" is parsed.
package_available() {
    local package="$1"
    local candidate

    candidate="$(
        LC_ALL=C apt-cache policy "$package" 2>/dev/null |
            awk '/^[[:space:]]*Candidate:/ { print $2; exit }' || true
    )"

    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_optional() {
    local packages=("$@")
    local selected=()
    local package

    for package in "${packages[@]}"; do
        if package_available "$package"; then
            selected+=("$package")
        else
            warn "Необязательный пакет недоступен, пропускаю: $package"
        fi
    done

    if ((${#selected[@]} == 0)); then
        return 0
    fi

    if ! run_apt install "${selected[@]}"; then
        warn "Групповая установка не удалась. Пробую установить пакеты по одному..."
        for package in "${selected[@]}"; do
            run_apt install "$package" ||
                warn "Не удалось установить необязательный пакет: $package"
        done
    fi
}

install_required() {
    run_apt install "$@" ||
        die "Не удалось установить обязательные пакеты: $*"
}

install_required_backports() {
    run_apt install -t trixie-backports "$@" ||
        die "Не удалось установить обязательные пакеты из trixie-backports: $*"
}

as_user() {
    runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" "$@"
}

# 1. System validation

[[ $EUID -eq 0 ]] || die "Запусти через sudo."

mkdir -p /var/log
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=/dev/null
source /etc/os-release

[[ "${ID:-}" == "debian" ]] || die "Требуется Debian."
[[ "${VERSION_CODENAME:-}" == "trixie" ]] ||
    die "Требуется Debian 13 Trixie."

choose_greeter

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64) ;;
    *) die "Архитектура $ARCH не поддерживается репозиторием Noctalia." ;;
esac

TARGET_USER="${SUDO_USER:-}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(
        getent passwd |
            awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }' ||
            true
    )"
fi

[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] ||
    die "Не удалось определить обычного пользователя."

getent passwd "$TARGET_USER" >/dev/null 2>&1 ||
    die "Пользователь $TARGET_USER не существует."

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"

[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] ||
    die "Не удалось определить домашний каталог пользователя $TARGET_USER."

[[ -n "$TARGET_GROUP" && -n "$TARGET_UID" ]] ||
    die "Не удалось определить группу или UID пользователя $TARGET_USER."

mkdir -p "$BACKUP"

info "Debian: ${PRETTY_NAME:-unknown}"
info "Архитектура: $ARCH"
info "Пользователь: $TARGET_USER"
info "Резервная копия: $BACKUP"

# 2. Virtual machine detection

VIRT="none"

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt --vm 2>/dev/null || true)"

    if [[ -z "$VIRT" ]]; then
        VIRT="none"
    fi
fi

info "Тип среды: $VIRT"

# 3. APT source preparation

# A DVD install may leave "deb cdrom:" entries that break apt-get update.
disable_cdrom_sources() {
    local file

    shopt -s nullglob

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list \
        /etc/apt/sources.list.d/*.sources
    do
        [[ -f "$file" ]] || continue

        if grep -qE '^[[:space:]]*(deb[[:space:]]+cdrom:|URIs:[[:space:]]*cdrom:)' "$file"; then
            cp -a "$file" "$BACKUP/$(basename "$file").bak"

            if [[ "$file" == *.sources ]]; then
                mv "$file" "$BACKUP/$(basename "$file").disabled"
            else
                sed -i -E 's|^([[:space:]]*deb[[:space:]]+)cdrom:|\1# cdrom:|' "$file"
            fi

            warn "Отключён CD-ROM источник: $file"
        fi
    done

    shopt -u nullglob
}

# Firmware lives in non-free-firmware; make sure the components are enabled.
ensure_debian_components() {
    local file
    local component

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/debian.sources \
        /etc/apt/sources.list.d/debian.list
    do
        [[ -f "$file" ]] || continue

        if [[ "$file" == *.sources ]]; then
            if grep -q '^Components:' "$file"; then
                [[ -e "$BACKUP/$(basename "$file").bak" ]] ||
                    cp -a "$file" "$BACKUP/$(basename "$file").bak"
                for component in contrib non-free non-free-firmware; do
                    if ! grep -qE "^Components:.*(^|[[:space:]])${component}([[:space:]]|$)" "$file"; then
                        sed -i -E "/^Components:/ s/[[:space:]]*$/ ${component}/" "$file"
                    fi
                done
                info "Проверены компоненты contrib/non-free/non-free-firmware в $file"
            fi
        else
            if grep -qE '^[[:space:]]*deb[[:space:]]' "$file"; then
                [[ -e "$BACKUP/$(basename "$file").bak" ]] ||
                    cp -a "$file" "$BACKUP/$(basename "$file").bak"
                for component in contrib non-free non-free-firmware; do
                    sed -i -E "/^[[:space:]]*deb[[:space:]]/ { /[[:space:]]${component}([[:space:]]|$)/! s/[[:space:]]*$/ ${component}/; }" "$file"
                done
                info "Проверены компоненты contrib/non-free/non-free-firmware в $file"
            fi
        fi
    done
}

disable_cdrom_sources
ensure_debian_components

# 4. Hardware detection / bootstrap

info "Обновление списков пакетов..."
apt_update

info "Установка базовых утилит..."
install_required \
    ca-certificates \
    curl \
    wget \
    gnupg \
    pciutils \
    usbutils \
    lsb-release

GPU_INFO="$(lspci -nn 2>/dev/null |
    grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"

info "Обнаруженные видеоустройства:"
printf '%s\n' "$GPU_INFO"

GPU_INTEL=0
GPU_AMD=0
GPU_NVIDIA=0

if grep -qi 'Intel' <<< "$GPU_INFO"; then GPU_INTEL=1; fi
if grep -qiE 'AMD|ATI' <<< "$GPU_INFO"; then GPU_AMD=1; fi
if grep -qi 'NVIDIA' <<< "$GPU_INFO"; then GPU_NVIDIA=1; fi

if [[ "$VIRT" == "none" ]]; then
    info "Обнаружена физическая система либо система без признаков VM."
else
    info "Обнаружена виртуальная машина: $VIRT"
fi

# 5. Debian repositories

if [[ ! -f /etc/apt/sources.list.d/debian-trixie-backports.sources ]]; then
    cat > /etc/apt/sources.list.d/debian-trixie-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    info "Добавлен репозиторий Debian trixie-backports."
fi

# 6. Noctalia repository

info "Подключение репозитория Noctalia..."

KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"

TMP_DIR="$(mktemp -d /tmp/umbriel-noctalia.XXXXXX)"

wget --timeout=60 --tries=3 -q "$KEYRING_URL" \
    -O "$TMP_DIR/noctalia-keyring.deb" ||
    die "Не удалось скачать ключ репозитория Noctalia."

dpkg -i "$TMP_DIR/noctalia-keyring.deb" ||
    die "Не удалось установить ключ репозитория Noctalia."

NOCTALIA_SOURCES="/etc/apt/sources.list.d/noctalia-trixie.sources"
if [[ -f "$NOCTALIA_SOURCES" ]]; then
    cp -a "$NOCTALIA_SOURCES" "$BACKUP/noctalia-trixie.sources.bak"
fi

wget --timeout=60 --tries=3 -q "$SOURCES_URL" \
    -O "$TMP_DIR/noctalia-trixie.sources" ||
    die "Не удалось скачать файл репозитория Noctalia."

# Do not rewrite the repository's Architectures field.  It is maintained by
# the repository owner; changing it locally can make apt silently ignore the
# repository or fail on an architecture for which no index exists.
install -m 0644 "$TMP_DIR/noctalia-trixie.sources" "$NOCTALIA_SOURCES"

grep -qE "^Architectures:.*(^|[[:space:]])${ARCH}([[:space:]]|$)" "$NOCTALIA_SOURCES" ||
    die "Репозиторий Noctalia не публикует индексы для архитектуры $ARCH."

apt_update

# 7. Core desktop packages

CRITICAL=(
    umbriel
    noctalia
    xdg-desktop-portal-umbriel
)

info "Проверка обязательных компонентов..."

for package in "${CRITICAL[@]}"; do
    package_available "$package" ||
        die "Критический пакет $package недоступен. Проверь репозитории и trixie-backports."
done

REQUIRED_DESKTOP=(
    dbus-user-session

    xdg-desktop-portal
    xdg-desktop-portal-gtk
    polkitd
    pkexec

    pipewire
    pipewire-audio
    pipewire-pulse
    pipewire-alsa
    wireplumber

    network-manager
    xwayland
    xdg-utils
    xdg-user-dirs
    libxkbcommon-tools
)

if [[ "$ENABLE_GREETER" == "1" ]]; then
    REQUIRED_DESKTOP+=(greetd)
fi

CORE=(
    libspa-0.2-bluetooth

    bluez

    kitty

    nautilus
    gnome-text-editor
    gnome-calculator
    neovim
    gvfs
    gvfs-backends
    gvfs-fuse

    firefox-esr
    mpv
    mpv-mpris
    wdisplays

    # Qt5/Qt6 runtime: Wayland platform plugins, SVG, QML and config tools.
    qtwayland5
    qt6-wayland
    qt5ct
    qt6ct
    libqt5svg5
    libqt6svg6
    qml-module-qtgraphicaleffects
    qml6-module-qt5compat-graphicaleffects
    qml6-module-qtquick-controls
    qml6-module-qtquick-layouts
    qml6-module-qtquick-window

    fonts-dejavu
    fonts-noto-core
    fonts-noto-extra
    fonts-noto-color-emoji
    fonts-noto-cjk
    fonts-liberation2
    fonts-jetbrains-mono

    mesa-utils
    mesa-vulkan-drivers
    mesa-va-drivers

    brightnessctl
    playerctl
    wl-clipboard

    adwaita-icon-theme
    papirus-icon-theme

    man-db
    sudo
    accountsservice
    gnome-keyring
    power-profiles-daemon
    upower
    ddcutil
    sound-theme-freedesktop
)

info "Установка основных пакетов рабочего стола..."
install_required "${REQUIRED_DESKTOP[@]}"
install_optional "${CORE[@]}"

# 8. Noctalia version selection

info "Проверка версии Noctalia..."

NOCTALIA_VERSION="$(
    LC_ALL=C apt-cache madison noctalia 2>/dev/null |
        awk -v prefix="$NOCTALIA_VERSION_PREFIX" '
            $3 == prefix ||
            index($3, prefix "-") == 1 ||
            index($3, prefix "+") == 1 { print $3; exit }
        ' || true
)"

if [[ -z "$NOCTALIA_VERSION" ]]; then
    NOCTALIA_VERSION="$(
        LC_ALL=C apt-cache policy noctalia 2>/dev/null |
            awk '/^[[:space:]]*Candidate:/ { print $2; exit }' || true
    )"

    if [[ -n "$NOCTALIA_VERSION" && "$NOCTALIA_VERSION" != "(none)" ]]; then
        warn "Noctalia $NOCTALIA_VERSION_PREFIX не найден. Будет установлена доступная версия: $NOCTALIA_VERSION"
    fi
fi

[[ -n "$NOCTALIA_VERSION" && "$NOCTALIA_VERSION" != "(none)" ]] ||
    die "Noctalia не найден в репозитории. Проверь apt-cache madison noctalia."

info "Будет установлена Noctalia: $NOCTALIA_VERSION"

# 9. Firmware and GPU support

FIRMWARE=(
    firmware-linux
    firmware-linux-nonfree
    firmware-misc-nonfree
    firmware-realtek
    firmware-iwlwifi
    firmware-mediatek
    firmware-atheros
    firmware-sof-signed
)

if ((GPU_INTEL)); then
    FIRMWARE+=(firmware-intel-graphics)
    FIRMWARE+=(intel-media-va-driver)
fi

if ((GPU_AMD)); then
    FIRMWARE+=(firmware-amd-graphics)
fi

if ((GPU_NVIDIA)); then
    FIRMWARE+=(firmware-nvidia-graphics)

    warn "NVIDIA обнаружена."
    warn "Проприетарный драйвер NVIDIA автоматически не устанавливается."
    warn "Для гибридной графики и passthrough требуется отдельная проверка."
fi

install_optional "${FIRMWARE[@]}"

# 10. Virtual machine guest packages

case "$VIRT" in

    kvm|qemu)
        install_optional \
            qemu-guest-agent \
            spice-vdagent
        ;;

    vmware)
        install_optional \
            open-vm-tools \
            open-vm-tools-desktop
        ;;

    oracle)
        warn "VirtualBox Guest Additions не входят в Debian 13."
        warn "Установи их вручную из ISO VirtualBox Guest Additions."
        ;;

    microsoft)
        install_optional \
            hyperv-daemons
        ;;

    none)
        info "Гостевые дополнения VM не требуются."
        ;;

    *)
        warn "Неизвестная виртуальная среда: $VIRT"
        ;;

esac

# 11. Install Noctalia and Umbriel

info "Установка Noctalia и Umbriel..."

if ! run_apt install "noctalia=$NOCTALIA_VERSION"; then
    warn "Не удалось установить Noctalia $NOCTALIA_VERSION. Пробую последнюю доступную версию."
    install_required noctalia
fi

# Umbriel and newer wlroots live in trixie-backports.
install_required_backports umbriel
install_required xdg-desktop-portal-umbriel

# 12. Install Noctalia Greeter

if [[ "$ENABLE_GREETER" == "1" ]]; then

    info "Установка Noctalia Greeter..."

    GREETER_SESSION_BIN="$(command -v noctalia-greeter-session || true)"

    if package_available noctalia-greeter; then
        install_required_backports noctalia-greeter

        if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
            noctalia-greeter-apply-appearance --setup-system ||
                warn "Не удалось выполнить noctalia-greeter-apply-appearance --setup-system."
        else
            warn "Не найдена команда настройки Greeter."
        fi
        [[ -n "$GREETER_SESSION_BIN" ]] ||
            die "noctalia-greeter-session не найден после установки greeter."
    else
        die "noctalia-greeter недоступен. Для установки без greeter запусти ENABLE_GREETER=0."
    fi

fi

# 13. Umbriel configuration

UCFG="$TARGET_HOME/.config/umbriel"
mkdir -p "$UCFG"

if [[ -f "$UCFG/config.toml" ]]; then

    cp -a "$UCFG/config.toml" \
        "$BACKUP/umbriel-config.toml"

    warn "Существующая конфигурация Umbriel сохранена."
    warn "Она не будет перезаписана."
    warn "Расширенные сочетания клавиш к ней не применены."

    if grep -qE '^[[:space:]]*cursor[[:space:]]*=' "$UCFG/config.toml"; then
        warn "В конфиге Umbriel найден cursor-эффект."
        warn "Глобальные анимации курсора не изменялись."
        warn "Анимация курсора включается только внутри kitty."
    fi

else

cat > "$UCFG/config.toml" <<'EOF'
[general]
autostart = ["noctalia"]
mod_key = "Super"
xwayland = true
show_cheatsheet = true
# xwayland_native_resolution = true
# xwayland_primary_output = "DP-1"
# nvidia_sync_workaround = false
# focus_on_activate = true
# attach_modal_dialogs = true
# honor_restored_maximize = true

# Cursor effects are off; kitty has its own trail.
[effects]
cursor = ""

[input.keyboard]
layout = "@KEYBOARD_LAYOUTS@"
options = "@KEYBOARD_OPTIONS@"
numlock_toggle = true
variant = "@KEYBOARD_VARIANT@"
model = "@KEYBOARD_MODEL@"
# track_layout = "window"
# repeat_rate = 25
# repeat_delay = 600

# [input.touchpad]
# tap = true
# natural_scroll = true
# accel_profile = "adaptive"
# disable_while_typing = true

# [input.mouse]
# natural_scroll = false
# accel_profile = "flat"

[input.cursor]
size = 24
# follows_focus = true

# Run `umbriel outputs` for connector names and modes.
# [output.DP-1]
# mode = "2560x1440@144"
# position = [0, 0]
# scale = 1.25
# transform = "normal"
# vrr = "fullscreen"
# hdr = "auto"

# [events]
# lid_close = "umbriel msg output-disable eDP-1"
# lid_open = "umbriel msg output-enable eDP-1"

# [environment]
# ELECTRON_OZONE_PLATFORM_HINT = "auto"
# SDL_VIDEODRIVER = "wayland"

# [screencast]
# disable_dynamic_confirmation = true

# Conservative visual defaults from the official Noctalia/Umbriel integration.
# They can be removed or adjusted later without changing the session model.
[appearance]
prefer_no_csd = true
border_width = 2
corner_radius = 10

[appearance.blur]
enabled = true
optimized = true
passes = 2
radius = 3
noise = 0.02
brightness = 0.9
contrast = 0.9
saturation = 1.1

[[window_rule]]
blur = true
blur_optimized = true

[[window_rule]]
match.app_id = "^dev.noctalia.Noctalia$"
default_floating = true
default_size = [1020, 900]

[[layer_rule]]
match.namespace = "^noctalia-(bar-[^\"]+|notification|dock|panel|attached-panel|osd)$"
blur = true
blur_ignore_alpha = 0.6
blur_optimized = false

[keybinds]
# --- Приложения и сессия ---
"Mod" = "spawn noctalia msg panel-toggle launcher"
"Mod+Return" = { action = "spawn kitty", repeat = false }
"Mod+E" = { action = "spawn nautilus", repeat = false }
"Mod+B" = { action = "spawn firefox-esr", repeat = false }
"Mod+Q" = { action = "window-close", repeat = false }
"Mod+Shift+Q" = { action = "window-kill", repeat = false }
"Mod+Escape" = "session-quit"
"Mod+Shift+Escape" = { action = "shortcuts-inhibit-toggle", allow_when_inhibited = true, repeat = false }
"Mod+Shift+L" = { action = "spawn noctalia msg session lock", repeat = false }
"Mod+Shift+K" = { action = "keyboard-layout-next", repeat = false }

# --- Панели Noctalia и скриншоты ---
"Mod+V" = { action = "spawn noctalia msg panel-toggle clipboard", repeat = false }
"Mod+Shift+C" = { action = "spawn noctalia msg panel-toggle control-center", repeat = false }
"Mod+Shift+W" = { action = "spawn noctalia msg panel-toggle wallpaper", repeat = false }
"Mod+Shift+D" = { action = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel", repeat = false }
"Print" = { action = "spawn noctalia msg screenshot-region", repeat = false }
"Mod+Shift+S" = { action = "spawn noctalia msg screenshot-region", repeat = false }
"Mod+Shift+F" = { action = "spawn noctalia msg screenshot-fullscreen", repeat = false }

# --- Фокус ---
"Mod+Left" = "window-focus-left"
"Mod+Down" = "window-focus-down"
"Mod+Up" = "window-focus-up"
"Mod+Right" = "window-focus-right"
"Mod+H" = "window-focus-left"
"Mod+J" = "window-focus-down"
"Mod+K" = "window-focus-up"
"Mod+L" = "window-focus-right"
"Mod+F1" = "window-focus-next"
"Mod+Shift+Left" = "column-move-left"
"Mod+Shift+Down" = "window-move-down"
"Mod+Shift+Up" = "window-move-up"
"Mod+Shift+Right" = "column-move-right"

# --- Состояние окна и раскладка ---
"Mod+T" = { action = "window-toggle-floating", repeat = false }
"Mod+Shift+T" = { action = "window-focus-switch-floating", repeat = false }
"Mod+P" = { action = "window-toggle-pinned", repeat = false }
"Mod+M" = { action = "window-toggle-maximize-to-edges", repeat = false }
"Mod+F" = { action = "window-toggle-fullscreen", repeat = false }
"Mod+Ctrl+F" = { action = "window-toggle-maximize", repeat = false }
"Mod+R" = "window-cycle-primary-extent"
"Mod+Shift+R" = "window-cycle-primary-extent-back"
"Mod+Minus" = "window-modify-primary-extent -0.02"
"Mod+Equal" = "window-modify-primary-extent +0.02"
"Mod+Ctrl+Minus" = "window-modify-secondary-extent -0.02"
"Mod+Ctrl+Equal" = "window-modify-secondary-extent +0.02"
"Mod+Comma" = "window-consume-left"
"Mod+Period" = "window-consume-right"
"Mod+Ctrl+Comma" = "window-consume-from-left"
"Mod+Ctrl+Period" = "window-consume-from-right"
"Mod+Alt+T" = { action = "layout-toggle-split", repeat = false }
"Mod+Alt+Space" = { action = "workspace-set-layout toggle", repeat = false }
"Mod+W" = { action = "column-toggle-tabbed", repeat = false }
"Mod+Alt+Right" = "column-focus-tab-next"
"Mod+Alt+Left" = "column-focus-tab-previous"
"Mod+WheelUp" = "window-focus-left"
"Mod+WheelDown" = "window-focus-right"
"Mod+O" = { action = "overview-toggle", repeat = false }

# --- Мониторы ---
"Mod+Ctrl+Left" = "output-focus-left"
"Mod+Ctrl+Right" = "output-focus-right"
"Mod+Ctrl+Up" = "output-focus-up"
"Mod+Ctrl+Down" = "output-focus-down"

# --- Рабочие столы ---
"Mod+1" = "workspace-switch 1"
"Mod+2" = "workspace-switch 2"
"Mod+3" = "workspace-switch 3"
"Mod+4" = "workspace-switch 4"
"Mod+5" = "workspace-switch 5"
"Mod+6" = "workspace-switch 6"
"Mod+7" = "workspace-switch 7"
"Mod+8" = "workspace-switch 8"
"Mod+9" = "workspace-switch 9"
"Mod+Shift+1" = "window-move-to-workspace 1"
"Mod+Shift+2" = "window-move-to-workspace 2"
"Mod+Shift+3" = "window-move-to-workspace 3"
"Mod+Shift+4" = "window-move-to-workspace 4"
"Mod+Shift+5" = "window-move-to-workspace 5"
"Mod+Shift+6" = "window-move-to-workspace 6"
"Mod+Shift+7" = "window-move-to-workspace 7"
"Mod+Shift+8" = "window-move-to-workspace 8"
"Mod+Shift+9" = "window-move-to-workspace 9"

# --- Scratchpad ---
"Mod+Shift+Space" = { action = "window-move-to-scratchpad", repeat = false }
"Mod+Space" = "scratchpad-toggle"
"Mod+Ctrl+Space" = { action = "window-restore-from-scratchpad", repeat = false }
"Mod+Tab" = "scratchpad-focus-next"

# --- Переключатель окон Noctalia ---
"Alt+Tab" = { action = "spawn noctalia msg window-switcher hold", repeat = false }
"Alt+Ctrl+Tab" = { action = "window-focus-previous", repeat = false }

# --- Мультимедиа, громкость и яркость ---
"XF86AudioRaiseVolume" = { action = "spawn noctalia msg volume-up", allow_when_locked = true }
"XF86AudioLowerVolume" = { action = "spawn noctalia msg volume-down", allow_when_locked = true }
"XF86AudioMute" = { action = "spawn noctalia msg volume-mute", allow_when_locked = true, repeat = false }
"XF86AudioPlay" = { action = "spawn noctalia msg media toggle", allow_when_locked = true, repeat = false }
"XF86AudioNext" = { action = "spawn noctalia msg media next", allow_when_locked = true }
"XF86AudioPrev" = { action = "spawn noctalia msg media previous", allow_when_locked = true }
"XF86MonBrightnessUp" = { action = "spawn noctalia msg brightness-up", allow_when_locked = true }
"XF86MonBrightnessDown" = { action = "spawn noctalia msg brightness-down", allow_when_locked = true }

# --- Справка и конфигурация ---
"Mod+Slash" = { action = "cheatsheet-toggle", repeat = false }
"Mod+Ctrl+R" = { action = "config-reload", repeat = false }

EOF

sed -i \
    -e "s|@KEYBOARD_LAYOUTS@|$KEYBOARD_LAYOUTS|g" \
    -e "s|@KEYBOARD_OPTIONS@|$KEYBOARD_OPTIONS|g" \
    -e "s|@KEYBOARD_VARIANT@|$KEYBOARD_VARIANT|g" \
    -e "s|@KEYBOARD_MODEL@|$KEYBOARD_MODEL|g" \
    "$UCFG/config.toml"

fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$UCFG"

# 14. Kitty: font, transparency, cursor trail

KCFG="$TARGET_HOME/.config/kitty"
mkdir -p "$KCFG"

KITTY_MANAGED="$KCFG/umbriel-kitty.conf"

cat > "$KITTY_MANAGED" <<'EOF'
# Managed by the installer; re-run it to refresh.
font_family JetBrains Mono
font_size 12.0
background_opacity 0.85
dynamic_background_opacity yes
cursor_trail 1
window_padding_width 10
confirm_os_window_close 0

# Font zoom
map ctrl+plus change_font_size all +1
map ctrl+equal change_font_size all +1
map ctrl+kp_add change_font_size all +1
map ctrl+minus change_font_size all -1
map ctrl+underscore change_font_size all -1
map ctrl+kp_subtract change_font_size all -1
map ctrl+0 change_font_size all 0
map ctrl+kp_0 change_font_size all 0

# Copy/paste and scrolling
map ctrl+c copy_or_interrupt
map ctrl+shift+c copy_to_clipboard
map ctrl+shift+v paste_from_clipboard
map page_up scroll_page_up
map page_down scroll_page_down
EOF

KITTY_CONF="$KCFG/kitty.conf"
KITTY_MARKER="# >>> umbriel-kitty-managed >>>"
KITTY_OLD_MARKER="# >>> umbriel-kitty-cursor-trail >>>"
KITTY_OLD_END="# <<< umbriel-kitty-cursor-trail <<<"
KITTY_BACKED_UP=0

if [[ ! -f "$KITTY_CONF" ]]; then

    cat > "$KITTY_CONF" <<'EOF'
# >>> umbriel-kitty-managed >>>
include $HOME/.config/kitty/umbriel-kitty.conf
# <<< umbriel-kitty-managed <<<
EOF

else

    if grep -qF "$KITTY_OLD_MARKER" "$KITTY_CONF" &&
        grep -qF "$KITTY_OLD_END" "$KITTY_CONF"
    then

        cp -L "$KITTY_CONF" "$BACKUP/kitty.conf"
        KITTY_BACKED_UP=1

        sed -i --follow-symlinks \
            '/^# >>> umbriel-kitty-cursor-trail >>>$/,/^# <<< umbriel-kitty-cursor-trail <<<$/d' \
            "$KITTY_CONF"

    fi

    if ! grep -qF "$KITTY_MARKER" "$KITTY_CONF"; then

        if [[ "$KITTY_BACKED_UP" -eq 0 ]]; then
            cp -L "$KITTY_CONF" "$BACKUP/kitty.conf"
        fi

        {
            printf '\n%s\n' "$KITTY_MARKER"
            cat <<'EOF'
include $HOME/.config/kitty/umbriel-kitty.conf
# <<< umbriel-kitty-managed <<<
EOF
        } >> "$KITTY_CONF"

    fi

fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$KCFG"

# 15. Optional plugin installer

PLUGIN_HELPER="$TARGET_HOME/.local/bin/noctalia-enable-plugins"

mkdir -p "$TARGET_HOME/.local/bin"

cat > "$PLUGIN_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command -v noctalia >/dev/null ||
    { echo "Noctalia CLI не найден."; exit 1; }

echo "Установка плагина управления мониторами..."

noctalia msg plugins enable muhammadessam/umbriel-monitor-control

echo
echo "Плагин включён."
echo
echo "Открыть панель мониторов:"
echo "noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"
echo
echo "Добавь виджет monitor на панель Noctalia."
echo "В Control Center можно добавить shortcut display."
echo "Масштаб: wdisplays или [output.<name>] scale в config.toml."
EOF

chmod +x "$PLUGIN_HELPER"

chown -R "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.local"

# 16. User folders

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    as_user xdg-user-dirs-update ||
        warn "xdg-user-dirs-update завершился с ошибкой."
else
    warn "xdg-user-dirs-update не найден."
fi

# 17. System services

enable_service() {
    local service="$1"

    if systemctl list-unit-files --type=service 2>/dev/null |
        grep -q "^${service}"
    then
        systemctl enable "$service" ||
            warn "Не удалось включить $service."
    fi
}

configure_keyboard() {
    [[ -n "$KEYBOARD_LAYOUTS" ]] || return 0

    if ! command -v localectl >/dev/null 2>&1; then
        warn "localectl не найден; настрой раскладку вручную."
        return 0
    fi

    if localectl set-x11-keymap \
        "$KEYBOARD_LAYOUTS" "$KEYBOARD_MODEL" "$KEYBOARD_VARIANT" "$KEYBOARD_OPTIONS"
    then
        info "Раскладка: $KEYBOARD_LAYOUTS ($KEYBOARD_OPTIONS)."
    else
        warn "Не удалось настроить раскладку через localectl."
    fi
}

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    enable_service NetworkManager.service
    enable_service bluetooth.service
    enable_service power-profiles-daemon.service

    if ! systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
        warn "NetworkManager.service не включён."
    fi

    if ! systemctl is-enabled bluetooth.service >/dev/null 2>&1; then
        warn "bluetooth.service не включён."
    fi
else
    warn "systemd не запущен. Включи NetworkManager и bluetooth вручную."
fi

configure_keyboard

# 18. Umbriel validation
GREETER_OK=1

if [[ "$ENABLE_GREETER" == "1" ]] && ! compgen -G "/dev/dri/card*" >/dev/null; then
    warn "Не найден /dev/dri/card*. Noctalia Greeter установлен, но не будет включён:"
    warn "без DRM-видеоустройства он обычно приводит к чёрному экрану."
    warn "Для VMware включи Accelerate 3D graphics и загрузи vmwgfx."
    GREETER_OK=0
fi

if command -v umbriel >/dev/null 2>&1; then

    info "Проверка конфигурации Umbriel..."

    UMBRIEL_RUNTIME="$(mktemp -d /tmp/umbriel-validate.XXXXXX)"
    chown "$TARGET_USER:$TARGET_GROUP" "$UMBRIEL_RUNTIME"
    chmod 700 "$UMBRIEL_RUNTIME"

    if ! as_user env XDG_RUNTIME_DIR="$UMBRIEL_RUNTIME" \
        umbriel config validate
    then
        warn "Конфигурация Umbriel не прошла проверку."
        warn "Greeter не будет включён до исправления ошибки."
        GREETER_OK=0
    fi

else
    warn "Команда umbriel не найдена после установки. Greeter не будет включён."
    GREETER_OK=0
fi

# 19. Greeter activation

if [[ "$ENABLE_GREETER" == "1" && "$GREETER_OK" == "1" ]]; then

    if ! command -v systemctl >/dev/null 2>&1 ||
       [[ ! -d /run/systemd/system ]]
    then
        warn "systemd не запущен. Включи greetd вручную."

    elif systemctl is-enabled greetd.service >/dev/null 2>&1; then
        info "greetd уже включён."

    elif systemctl is-enabled display-manager.service >/dev/null 2>&1; then
        CURRENT_DM="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
        if [[ "$GREETER_CHOICE" == "install" && -n "$CURRENT_DM" ]]; then
            CURRENT_DM_UNIT="$(basename "$CURRENT_DM")"
            if systemctl disable "$CURRENT_DM_UNIT"; then
                info "$CURRENT_DM_UNIT отключён для следующей загрузки; текущая сессия не остановлена."
            else
                warn "Не удалось отключить $CURRENT_DM_UNIT."
            fi
            if systemctl enable --force greetd.service; then
                info "greetd включён для следующей загрузки."
            else
                warn "Не удалось включить greetd.service."
            fi
        else
            warn "Обнаружен другой display-manager. Он будет сохранён."
        fi

    elif systemctl list-unit-files --type=service 2>/dev/null |
        grep -q '^greetd.service'
    then
        if systemctl enable --force greetd.service; then
            info "greetd включён для следующей загрузки."
        else
            warn "Не удалось включить greetd.service."
        fi

    else
        warn "greetd.service не найден."
    fi

fi

if [[ "$ENABLE_GREETER" == "1" && "$GREETER_OK" != "1" ]]; then
    warn "Greeter установлен, но не включён из-за ошибки проверки конфигурации."
    warn "После исправления выполни: sudo systemctl enable --force greetd.service"
fi

if [[ "$ENABLE_GREETER" == "1" && "$GREETER_OK" == "1" && "$GREETER_CHOICE" == "install" ]] &&
   command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl set-default graphical.target ||
        warn "Не удалось установить graphical.target по умолчанию."
fi

# 20. Diagnostic helper

cat > /usr/local/bin/umbriel-diagnostics <<'EOF'
#!/usr/bin/env bash
set -u

echo "== date =="
date -Is

echo
echo "== os =="
cat /etc/os-release

echo
echo "== default target =="
systemctl get-default 2>&1

echo
echo "== display manager =="
systemctl status display-manager --no-pager 2>&1 || true

echo
echo "== greetd =="
systemctl status greetd --no-pager 2>&1 || true
journalctl -u greetd -b --no-pager 2>&1 | tail -200

echo
echo "== greeter state =="
ls -ld /var/lib/noctalia-greeter 2>&1 || true
ls -la /var/lib/noctalia-greeter 2>&1 || true

echo
echo "== greetd config =="
cat /etc/greetd/config.toml 2>&1 || true

echo
echo "== dri and gpu =="
ls -l /dev/dri 2>&1 || true
lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true

echo
echo "== wayland sessions =="
ls -l /usr/share/wayland-sessions 2>&1 || true

echo
echo "== umbriel =="
umbriel config validate 2>&1 || true
umbriel outputs 2>&1 || true

echo
echo "== install log =="
grep -nE '\[WARN\]|\[ERROR\]|greetd|Greeter|noctalia-greeter|display-manager' \
    /var/log/umbriel-noctalia-install.log 2>/dev/null | tail -150 || true
EOF

chmod 0755 /usr/local/bin/umbriel-diagnostics

# 21. Final report

echo
echo "=================================================="
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo "=================================================="

echo "Версия скрипта: $SCRIPT_VERSION"
echo "Debian: ${PRETTY_NAME:-unknown}"
echo "Архитектура: $ARCH"
echo "Виртуализация: $VIRT"
echo "Пользователь: $TARGET_USER"
echo "Greeter policy: ${GREETER_CHOICE:-unknown}"

echo
echo "Noctalia:"
dpkg-query -W -f='${Version}\n' noctalia 2>/dev/null || true

echo
echo "Umbriel:"
dpkg-query -W -f='${Version}\n' umbriel 2>/dev/null || true

echo
echo "Greeter:"
dpkg-query -W -f='${Version}\n' noctalia-greeter 2>/dev/null || true

echo
echo "Горячие клавиши:"
echo "Super         - Launcher"
echo "Super+Enter   - Kitty"
echo "Super+E       - Nautilus"
echo "Super+B       - Firefox"
echo "Super+Q       - Закрыть окно"
echo "Super+O       - Overview"
echo "Super+Escape  - Завершить сессию"
echo "Super+Shift+D - Управление мониторами"
echo "Super+Slash   - Полный список сочетаний"

echo
echo "Программы по умолчанию:"
echo "Kitty, Neovim, Nautilus, GNOME Text Editor,"
echo "Firefox, MPV, GNOME Calculator, Qt5/Qt6."

echo
echo "Мониторы:"
echo "Super+Shift+D - панель Noctalia (разрешение, частота, поворот, положение)."
echo "Масштаб: wdisplays или [output.<name>] scale в config.toml."

echo
echo "Раскладка:"
echo "$KEYBOARD_LAYOUTS, переключение $KEYBOARD_OPTIONS."
echo "Список раскладок: umbriel keyboard-layouts"

echo
echo "После первого входа выполни:"
echo "$PLUGIN_HELPER"

echo
echo "Проверка мониторов:"
echo "umbriel outputs"

echo
echo "Проверка конфигурации:"
echo "umbriel config validate"

echo
echo "Анимация курсора:"
echo "Включена только в kitty (cursor_trail 1)."
echo "Глобальные cursor-эффекты Umbriel отключены."
echo "Терминал kitty: JetBrains Mono 12 pt, прозрачность 0.85."
echo "Сочетания клавиш Umbriel: расширенный набор, см. Mod+Slash."
echo "Существующий config.toml не перезаписывается;"
echo "новые сочетания применяются только к конфигу, созданному скриптом."

echo
echo "Резервные копии: $BACKUP"
echo "Журнал: $LOG"

echo
echo "ВАЖНО:"
echo "1. Перед перезагрузкой убедись, что доступен TTY."
echo "2. Проверь конфигурацию Umbriel."
echo "3. Убедись, что Greeter видит сессию Umbriel."
echo "4. Проприетарный драйвер NVIDIA не устанавливался."
echo "5. VirtualBox Guest Additions устанавливаются вручную."

echo
echo "=================================================="
