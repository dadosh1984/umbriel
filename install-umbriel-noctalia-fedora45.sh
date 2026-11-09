#!/usr/bin/env bash
# Fedora 45: Umbriel + Noctalia + Noctalia Greeter (Wayland).
# Umbriel and the greeter come from Terra; --accept-terra is required.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.1"
NOCTALIA_VERSION_PREFIX="${NOCTALIA_VERSION_PREFIX:-5.4.1}"
ENABLE_GREETER="${ENABLE_GREETER:-1}"
START_GREETER="${START_GREETER:-0}"
ACCEPT_TERRA="${ACCEPT_TERRA:-0}"
KEYBOARD_LAYOUTS="${KEYBOARD_LAYOUTS:-us,ru}"
KEYBOARD_MODEL="${KEYBOARD_MODEL:-pc105}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT:-}"
KEYBOARD_OPTIONS="${KEYBOARD_OPTIONS:-grp:alt_shift_toggle}"

LOG="/var/log/umbriel-noctalia-fedora-install.log"
BACKUP="/var/backups/umbriel-noctalia-fedora-$(date +%Y%m%d-%H%M%S)"

UMBRIEL_RUNTIME=""
ORIGINAL_DEFAULT_TARGET=""
ORIGINAL_DM_TARGET=""

cleanup() {
    [[ -n "$UMBRIEL_RUNTIME" && -d "$UMBRIEL_RUNTIME" ]] && rm -rf "$UMBRIEL_RUNTIME"
}

trap cleanup EXIT

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Использование:
  sudo ./install-umbriel-noctalia-fedora45.sh --accept-terra [опции]

Опции:
  --accept-terra   Разрешить сторонний репозиторий Terra.
                   Без него Umbriel и Noctalia Greeter установить нельзя.
  --no-greeter     Не устанавливать и не включать Noctalia Greeter.
  --start-greeter  Запустить greetd сразу; без этого только включить его на следующую загрузку.
  -h, --help       Показать эту справку.

Переменные окружения:
  ENABLE_GREETER=0        То же, что --no-greeter.
  START_GREETER=1         Запустить greetd сразу после настройки.
  NOCTALIA_VERSION_PREFIX Ожидаемая версия Noctalia (по умолчанию 5.4.1).
  KEYBOARD_LAYOUTS        Список раскладок (по умолчанию us,ru).
  KEYBOARD_VARIANT        Варианты раскладок через запятую.
  KEYBOARD_OPTIONS        Опция переключения (по умолчанию grp:alt_shift_toggle).
EOF
}

while (($#)); do
    case "$1" in
        --accept-terra)
            ACCEPT_TERRA=1
            ;;
        --no-greeter)
            ENABLE_GREETER=0
            ;;
        --start-greeter)
            START_GREETER=1
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

# 1. System validation

[[ $EUID -eq 0 ]] || die "Запусти через sudo."

mkdir -p /var/log
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=/dev/null
source /etc/os-release

[[ "${ID:-}" == "fedora" ]] || die "Требуется Fedora."
[[ "${VERSION_ID:-}" == "45" ]] ||
    die "Требуется Fedora 45. Обнаружено: ${PRETTY_NAME:-unknown}."

if command -v rpm-ostree >/dev/null 2>&1; then
    die "rpm-ostree (Silverblue/Kinoite) не поддерживается. Нужна обычная Fedora."
fi

command -v dnf >/dev/null 2>&1 || die "Не найден dnf."

[[ -d /run/systemd/system ]] ||
    die "systemd не запущен. Загрузись в обычную систему и повтори."

ORIGINAL_DEFAULT_TARGET="$(systemctl get-default 2>/dev/null || true)"
if [[ -L /etc/systemd/system/display-manager.service ]]; then
    ORIGINAL_DM_TARGET="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
fi

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|aarch64) ;;
    *) die "Архитектура $ARCH не поддерживается Terra/Noctalia." ;;
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

info "Fedora: ${PRETTY_NAME:-unknown}"
info "Архитектура: $ARCH"
info "Пользователь: $TARGET_USER (UID $TARGET_UID)"
info "Резервная копия: $BACKUP"

# 2. Third-party repository consent

if [[ "$ACCEPT_TERRA" != "1" ]]; then
    cat >&2 <<'EOF'

[ERROR] Для Fedora нужен сторонний репозиторий Terra.

Официальные репозитории Fedora 45 содержат:
  - noctalia
  - greetd

Но НЕ содержат:
  - umbriel-nightly
  - xdg-desktop-portal-umbriel-nightly
  - noctalia-greeter

Эти три пакета есть только в Terra (https://repos.fyralabs.com/).
Если ты согласен на сторонний репозиторий, запусти:

  sudo ./install-umbriel-noctalia-fedora45.sh --accept-terra

EOF
    exit 1
fi

# 3. Virtualization and GPU detection

VIRT="$(systemd-detect-virt --vm 2>/dev/null || true)"
if [[ -z "$VIRT" ]]; then
    VIRT="none"
fi

info "Тип среды: $VIRT"

# 4. Base utilities and Terra bootstrap

info "Обновление метаданных dnf..."
dnf -y makecache ||
    die "dnf makecache завершился с ошибкой. Проверь сеть и репозитории."

info "Установка базовых утилит..."
dnf install -y \
    ca-certificates \
    curl \
    pciutils \
    usbutils ||
    die "Не удалось установить базовые утилиты."

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

info "Подключение репозитория Terra..."

if ! dnf repolist --enabled 2>/dev/null | grep -q '^terra'; then
    dnf install -y --nogpgcheck \
        --repofrompath "terra,https://repos.fyralabs.com/terra${VERSION_ID}" \
        terra-release ||
        die "Не удалось установить terra-release."
fi

dnf -y makecache --repo terra ||
    die "Не удалось загрузить метаданные Terra."

dnf repolist --enabled 2>/dev/null | grep -q '^terra' ||
    die "Репозиторий Terra не включён."

info "Проверка доступности пакетов Umbriel в Terra..."

for package in umbriel-nightly xdg-desktop-portal-umbriel-nightly; do
    dnf -q --enablerepo=terra list --available "$package" >/dev/null 2>&1 ||
    rpm -q "$package" >/dev/null 2>&1 ||
        die "Пакет $package недоступен в Terra для Fedora $VERSION_ID."
done

if [[ "$ENABLE_GREETER" == "1" ]]; then
    dnf -q --enablerepo=terra list --available noctalia-greeter >/dev/null 2>&1 ||
    rpm -q noctalia-greeter >/dev/null 2>&1 ||
        die "Пакет noctalia-greeter недоступен в Terra для Fedora $VERSION_ID."
fi

# 5. Package helpers

install_required() {
    dnf install -y "$@" ||
        die "Не удалось установить обязательные пакеты: $*"
}

install_required_terra() {
    dnf install -y --enablerepo=terra "$@" ||
        die "Не удалось установить пакеты Terra: $*"
}

install_optional() {
    local packages=("$@")
    local package

    ((${#packages[@]} > 0)) || return 0

    if dnf install -y --skip-unavailable "${packages[@]}"; then
        :
    else
        warn "Групповая установка не удалась. Пробую установить пакеты по одному..."
        for package in "${packages[@]}"; do
            dnf install -y "$package" ||
                warn "Не удалось установить необязательный пакет: $package"
        done
    fi

    for package in "${packages[@]}"; do
        rpm -q "$package" >/dev/null 2>&1 ||
            warn "Пакет отсутствует в репозиториях и был пропущен: $package"
    done
}

as_user() {
    runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" "$@"
}

fix_context() {
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$1" 2>/dev/null || true
    fi
}

# 6. Core desktop packages

CORE=(
    dbus
    dbus-broker
    dbus-tools

    xdg-desktop-portal
    xdg-desktop-portal-gtk
    xdg-dbus-proxy

    polkit

    pipewire
    pipewire-pulseaudio
    pipewire-alsa
    wireplumber

    NetworkManager
    bluez

    kitty
    kitty-terminfo

    nautilus
    gnome-text-editor
    gnome-calculator
    neovim
    gvfs
    gvfs-fuse
    gvfs-mtp
    gvfs-smb

    firefox
    mpv
    mpv-mpris
    wdisplays

    # Qt5/Qt6 runtime: Wayland platform plugins, SVG, QML and config tools.
    qt5-qtwayland
    qt6-qtwayland
    qt5ct
    qt6ct
    qt5-qtsvg
    qt6-qtsvg
    qt5-qtgraphicaleffects
    qt6-qt5compat
    qt6-qtmultimedia

    xorg-x11-server-Xwayland
    xorg-x11-xauth
    xdg-utils
    xdg-user-dirs
    libxkbcommon-utils

    google-noto-sans-fonts
    google-noto-sans-cjk-fonts
    google-noto-color-emoji-fonts
    dejavu-sans-fonts
    liberation-sans-fonts
    jetbrains-mono-fonts

    mesa-dri-drivers
    mesa-vulkan-drivers
    mesa-libEGL
    mesa-libGL
    mesa-libgbm
    libglvnd-egl
    libglvnd-gles
    libglvnd-glx
    egl-wayland
    vulkan-loader
    libva
    libva-utils

    brightnessctl
    playerctl
    wl-clipboard

    adwaita-icon-theme
    papirus-icon-theme

    man-db
    accountsservice

    gnome-keyring
    power-profiles-daemon
    upower
    ddcutil
    sound-theme-freedesktop
)

info "Установка основных пакетов рабочего стола..."
install_optional "${CORE[@]}"

if [[ "$ENABLE_GREETER" == "1" ]]; then
    install_required greetd
fi

# 7. Noctalia and Umbriel

info "Установка Noctalia..."
install_required noctalia

info "Установка Umbriel и portal..."
install_required_terra \
    umbriel-nightly \
    xdg-desktop-portal-umbriel-nightly

for package in noctalia umbriel-nightly xdg-desktop-portal-umbriel-nightly; do
    rpm -q "$package" >/dev/null 2>&1 ||
        die "Критический пакет $package не установлен."
done

NOCTALIA_INSTALLED="$(rpm -q --qf '%{VERSION}' noctalia 2>/dev/null || true)"

info "Установлена Noctalia: ${NOCTALIA_INSTALLED:-unknown}"

if [[ -n "$NOCTALIA_INSTALLED" &&
      "$NOCTALIA_INSTALLED" != "$NOCTALIA_VERSION_PREFIX"* ]]; then
    warn "Ожидалась Noctalia $NOCTALIA_VERSION_PREFIX, установлена $NOCTALIA_INSTALLED."
    warn "Проверь совместимость Umbriel и Noctalia."
fi

# Umbriel ships the session entry; recreate it if packaging drops it.
if [[ ! -f /usr/share/wayland-sessions/umbriel.desktop ]]; then
    cat > /usr/share/wayland-sessions/umbriel.desktop <<'EOF'
[Desktop Entry]
Name=Umbriel
Comment=Umbriel Wayland Compositor
Exec=start-umbriel
Type=Application
DesktopNames=Umbriel
EOF
fi

# 8. Noctalia Greeter

if [[ "$ENABLE_GREETER" == "1" ]]; then
    info "Установка Noctalia Greeter..."
    install_required_terra noctalia-greeter

    rpm -q noctalia-greeter >/dev/null 2>&1 ||
        die "Пакет noctalia-greeter не установлен."
fi

# 9. Firmware and GPU support

FIRMWARE=(
    linux-firmware
    alsa-sof-firmware
)

if ((GPU_INTEL)); then
    FIRMWARE+=(intel-gpu-firmware)
fi

if ((GPU_AMD)); then
    FIRMWARE+=(amd-gpu-firmware)
fi

if ((GPU_NVIDIA)); then
    FIRMWARE+=(nvidia-gpu-firmware)
fi

info "Установка firmware..."
install_optional "${FIRMWARE[@]}"

if ((GPU_NVIDIA)); then
    warn "Обнаружена NVIDIA."
    warn "Проприетарный драйвер NVIDIA в официальных репозиториях Fedora отсутствует."
    warn "Он находится в RPM Fusion. Скрипт его не подключает и не устанавливает."
    warn "Для Wayland с проприетарным драйвером нужен nvidia-drm.modeset=1."

    if command -v grubby >/dev/null 2>&1; then
        if grubby --update-kernel=ALL --args="nvidia-drm.modeset=1"; then
            info "Добавлен параметр ядра nvidia-drm.modeset=1."
        else
            warn "Не удалось добавить nvidia-drm.modeset=1 через grubby."
        fi
    else
        warn "grubby не найден. Добавь nvidia-drm.modeset=1 вручную."
    fi
fi

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
        warn "VirtualBox Guest Additions не входят в официальные репозитории Fedora."
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

# 11. Umbriel configuration

UCFG="$TARGET_HOME/.config/umbriel"
CONFIG_CREATED=0
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
"Mod+B" = { action = "spawn firefox", repeat = false }
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

    CONFIG_CREATED=1

fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$UCFG"

fix_context "$UCFG"

# 12. Kitty: font, transparency, cursor trail

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

fix_context "$KCFG"

# 13. Optional plugin installer

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

# 14. User folders

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    as_user xdg-user-dirs-update ||
        warn "xdg-user-dirs-update завершился с ошибкой."
else
    warn "xdg-user-dirs-update не найден."
fi

# 15. System services

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

enable_service NetworkManager.service
enable_service bluetooth.service
enable_service power-profiles-daemon.service
configure_keyboard

if ! systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
    warn "NetworkManager.service не включён."
fi

if ! systemctl is-enabled bluetooth.service >/dev/null 2>&1; then
    warn "bluetooth.service не включён."
fi

# 16. Umbriel validation

GREETER_OK=1

if command -v umbriel >/dev/null 2>&1; then

    info "Проверка конфигурации Umbriel..."

    UMBRIEL_RUNTIME="$(mktemp -d /tmp/umbriel-validate.XXXXXX)"
    chown "$TARGET_USER:$TARGET_GROUP" "$UMBRIEL_RUNTIME"
    chmod 700 "$UMBRIEL_RUNTIME"

    if ! as_user env XDG_RUNTIME_DIR="$UMBRIEL_RUNTIME" \
        umbriel config validate
    then
        warn "Конфигурация Umbriel не прошла проверку."

        if [[ "$CONFIG_CREATED" != "1" ]]; then
            warn "Это существующая конфигурация пользователя."
            warn "Не перезаписываю её. Greeter не будет включён."
            GREETER_OK=0
        else
            warn "Пробую минимальную конфигурацию без include/effects..."

            cp -a "$UCFG/config.toml" \
                "$BACKUP/umbriel-config.invalid.toml" 2>/dev/null || true

            cat > "$UCFG/config.toml" <<'EOF'
[general]
autostart = ["noctalia"]
mod_key = "Super"
xwayland = true
show_cheatsheet = true

[keybinds]
"Mod" = "spawn noctalia msg panel-toggle launcher"
"Mod+Return" = "spawn kitty"
"Mod+T" = "window-toggle-floating"
"Mod+E" = "spawn nautilus"
"Mod+Q" = "window-close"
"Mod+O" = "overview-toggle"
"Mod+Escape" = "session-quit"
"Mod+Shift+D" = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"
"Mod+Shift+K" = "keyboard-layout-next"

"XF86AudioRaiseVolume" = { action = "spawn noctalia msg volume-up", allow_when_locked = true }
"XF86AudioLowerVolume" = { action = "spawn noctalia msg volume-down", allow_when_locked = true }
"XF86AudioMute" = { action = "spawn noctalia msg volume-mute", allow_when_locked = true, repeat = false }
"XF86AudioPlay" = { action = "spawn noctalia msg media toggle", allow_when_locked = true, repeat = false }
"XF86AudioNext" = { action = "spawn noctalia msg media next", allow_when_locked = true }
"XF86AudioPrev" = { action = "spawn noctalia msg media previous", allow_when_locked = true }
"XF86MonBrightnessUp" = { action = "spawn noctalia msg brightness-up", allow_when_locked = true }
"XF86MonBrightnessDown" = { action = "spawn noctalia msg brightness-down", allow_when_locked = true }
EOF

            chown -R "$TARGET_USER:$TARGET_GROUP" "$UCFG"

            if ! as_user env XDG_RUNTIME_DIR="$UMBRIEL_RUNTIME" \
                umbriel config validate
            then
                warn "Минимальная конфигурация тоже не прошла проверку."
                warn "Greeter не будет включён, чтобы не получить чёрный экран."
                GREETER_OK=0
            fi
        fi
    fi

    rm -rf "$UMBRIEL_RUNTIME"
else
    warn "Команда umbriel не найдена."
    GREETER_OK=0
fi

# 17. Greeter configuration and activation

greeter_rollback() {
    systemctl stop greetd.service 2>/dev/null || true
    systemctl disable greetd.service 2>/dev/null || true
    systemctl reset-failed greetd.service 2>/dev/null || true

    if [[ -n "$ORIGINAL_DM_TARGET" ]]; then
        ln -sfn "$ORIGINAL_DM_TARGET" /etc/systemd/system/display-manager.service
    elif [[ -z "$ORIGINAL_DM_TARGET" ]]; then
        rm -f /etc/systemd/system/display-manager.service
    fi

    if [[ -n "$ORIGINAL_DEFAULT_TARGET" ]]; then
        systemctl set-default "$ORIGINAL_DEFAULT_TARGET" 2>/dev/null || true
    fi
    systemctl daemon-reload 2>/dev/null || true
}

if [[ "$ENABLE_GREETER" == "1" ]]; then

    info "Настройка Noctalia Greeter..."

    GREETER_SESSION_BIN="$(command -v noctalia-greeter-session || true)"

    if command -v getenforce >/dev/null 2>&1 &&
       [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
        warn "SELinux Enforcing. При проблемах с greeter проверь AVC:"
        warn "  sudo ausearch -m avc -ts recent"
    fi

    if [[ -z "$GREETER_SESSION_BIN" ]]; then
        warn "noctalia-greeter-session не найден."
        GREETER_OK=0
    fi

    if [[ ! -f /usr/share/wayland-sessions/umbriel.desktop ]]; then
        warn "Нет /usr/share/wayland-sessions/umbriel.desktop."
        GREETER_OK=0
    fi

    DRI_OK=0
    if compgen -G "/dev/dri/card*" >/dev/null; then
        DRI_OK=1
    fi

    if ((DRI_OK == 0)); then
        warn "Не найден /dev/dri/card*."
        warn "Greeter не сможет создать DRM-композитор и покажет чёрный экран."
        warn "VM: включи 3D acceleration. NVIDIA: нужен рабочий DRM-драйвер."
        GREETER_OK=0
    fi

    GREETER_USER=""
    GREETER_GROUP=""
    if [[ -f /etc/greetd/config.toml ]]; then
        GREETER_USER="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/ { gsub(/[[:space:]\"]/, "", $2); print $2; exit }' /etc/greetd/config.toml || true)"
    fi
    if [[ -z "$GREETER_USER" ]]; then
        if id -u greeter >/dev/null 2>&1; then
            GREETER_USER="greeter"
        elif id -u greetd >/dev/null 2>&1; then
            GREETER_USER="greetd"
        else
            GREETER_USER="greeter"
        fi
    fi
    GREETER_GROUP="$(id -gn "$GREETER_USER" 2>/dev/null || true)"
    if [[ -z "$GREETER_GROUP" ]]; then
        systemd-sysusers 2>/dev/null || true
        GREETER_GROUP="$(id -gn "$GREETER_USER" 2>/dev/null || true)"
    fi

    if ! id -u "$GREETER_USER" >/dev/null 2>&1; then
        warn "Пользователь $GREETER_USER не создан."
        GREETER_OK=0
    elif [[ -z "$GREETER_GROUP" ]]; then
        warn "Группа для пользователя $GREETER_USER не создана."
        GREETER_OK=0
    else
        for group in video render input; do
            if getent group "$group" >/dev/null 2>&1; then
                usermod -aG "$group" "$GREETER_USER" 2>/dev/null || true
            fi
        done
    fi

    mkdir -p /etc/greetd

    if [[ -f /etc/greetd/config.toml ]]; then
        cp -a /etc/greetd/config.toml \
            "$BACKUP/greetd-config.toml"
    fi

    cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "${GREETER_SESSION_BIN}"
user = "${GREETER_USER}"
EOF

    chmod 0644 /etc/greetd/config.toml

    if id -u "$GREETER_USER" >/dev/null 2>&1 &&
       getent group "$GREETER_GROUP" >/dev/null 2>&1; then
        install -d -m 0750 -o "$GREETER_USER" -g "$GREETER_GROUP" /var/lib/noctalia-greeter
        chown -R "$GREETER_USER:$GREETER_GROUP" /var/lib/noctalia-greeter 2>/dev/null || true
        chmod 0750 /var/lib/noctalia-greeter 2>/dev/null || true
    else
        warn "Не удалось подготовить /var/lib/noctalia-greeter."
        GREETER_OK=0
    fi

    fix_context /var/lib/noctalia-greeter

    if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
        if ! GREETER_USER="$GREETER_USER" noctalia-greeter-apply-appearance --setup-system; then
            warn "Не удалось выполнить noctalia-greeter-apply-appearance --setup-system."
            GREETER_OK=0
        fi
    else
        warn "noctalia-greeter-apply-appearance не установлен."
        GREETER_OK=0
    fi

    if [[ ! -f /var/lib/noctalia-greeter/greeter.toml ]]; then
        warn "greeter.toml не создан. Greeter может использовать настройки по умолчанию."
    fi

    if [[ "$GREETER_OK" == "1" ]]; then

        info "Включение greetd..."

        if [[ -L /etc/systemd/system/display-manager.service ]]; then
            CURRENT_DM="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
            if [[ -n "$CURRENT_DM" && "$CURRENT_DM" != */greetd.service ]]; then
                warn "Обнаружен другой display-manager: $CURRENT_DM"
                warn "Автоматическое переключение не выполняется. Отключи его вручную из TTY перед включением greetd."
                GREETER_OK=0
            fi
        fi

        if systemctl is-active --quiet graphical.target 2>/dev/null; then
            warn "Система уже в graphical.target."
            warn "Запуск greetd может завершить текущую графическую сессию."
        fi

        if ! systemctl list-unit-files --type=service 2>/dev/null |
            grep -q '^greetd.service'; then
            warn "greetd.service не найден."
            GREETER_OK=0
        fi

        systemctl daemon-reload

        if [[ "$GREETER_OK" == "1" ]] &&
           ! systemctl enable --force greetd.service; then
            warn "Не удалось включить greetd.service."
            GREETER_OK=0
        fi

        if [[ "$GREETER_OK" == "1" ]] &&
           ! systemctl set-default graphical.target; then
            warn "Не удалось установить graphical.target по умолчанию."
            GREETER_OK=0
        fi

        if [[ "$GREETER_OK" == "1" && "$START_GREETER" == "1" ]]; then

            CURRENT_TTY="$(tty 2>/dev/null || true)"

            if [[ "$CURRENT_TTY" == "/dev/tty1" ]]; then
                warn "Скрипт запущен на tty1. greetd не запускаю, чтобы не оборвать сессию."
                warn "Перезагрузись или выполни: sudo systemctl start greetd"
            else
                if systemctl start greetd.service; then
                    for _ in {1..10}; do
                        if systemctl is-active --quiet greetd.service; then
                            break
                        fi
                        sleep 1
                    done

                    if systemctl is-active --quiet greetd.service; then
                        info "greetd запущен."
                    else
                        warn "greetd не стал активным."
                        journalctl -u greetd -b --no-pager |
                            tail -120 || true

                        greeter_rollback

                        warn "Возврат на multi-user.target, чтобы не получить чёрный экран."
                        GREETER_OK=0
                    fi
                else
                    warn "systemctl start greetd завершился с ошибкой."
                    journalctl -u greetd -b --no-pager |
                        tail -120 || true

                    greeter_rollback

                    GREETER_OK=0
                fi
            fi
        fi
    fi

    if [[ "$GREETER_OK" != "1" ]]; then
        greeter_rollback

        warn "Greeter установлен, но не включён."
        warn "Система останется в multi-user.target с текстовой консолью."
        warn "После исправления причины включи вручную:"
        warn "  sudo systemctl enable --force greetd.service"
        warn "  sudo systemctl set-default graphical.target"
        warn "  sudo systemctl start greetd.service"
    fi

else
    warn "Noctalia Greeter отключён (--no-greeter)."
fi

# 18. Diagnostic helper

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
systemctl get-default

echo
echo "== greetd status =="
systemctl status greetd --no-pager 2>&1

echo
echo "== greetd enabled =="
systemctl is-enabled greetd display-manager 2>&1

echo
echo "== greetd journal =="
journalctl -u greetd -b --no-pager 2>&1 | tail -200

echo
echo "== greeter journal =="
journalctl -b -t noctalia-greeter --no-pager 2>&1 | tail -200

echo
echo "== greetd config =="
cat /etc/greetd/config.toml 2>&1

echo
echo "== greeter state =="
ls -ld /var/lib/noctalia-greeter 2>&1
ls -la /var/lib/noctalia-greeter 2>&1

echo
echo "== dri =="
ls -l /dev/dri 2>&1

echo
echo "== gpu =="
lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true

echo
echo "== virtualization =="
systemd-detect-virt 2>&1 || true

echo
echo "== selinux =="
getenforce 2>&1 || true
if command -v ausearch >/dev/null 2>&1; then
    ausearch -m avc -ts recent 2>&1 | tail -80 || true
fi

echo
echo "== kernel cmdline =="
cat /proc/cmdline

echo
echo "== seat =="
loginctl seat-status seat0 2>&1 | head -60

echo
echo "== wayland sessions =="
ls -l /usr/share/wayland-sessions 2>&1

echo
echo "== install log =="
grep -nE '\[WARN\]|\[ERROR\]|greetd|Greeter|noctalia-greeter|display-manager|Terra' \
    /var/log/umbriel-noctalia-fedora-install.log 2>/dev/null | tail -150
EOF

chmod 0755 /usr/local/bin/umbriel-diagnostics

# 19. Final report

echo
echo "=================================================="
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo "=================================================="

echo "Версия скрипта: $SCRIPT_VERSION"
echo "Fedora: ${PRETTY_NAME:-unknown}"
echo "Архитектура: $ARCH"
echo "Виртуализация: $VIRT"
echo "Пользователь: $TARGET_USER"

echo
echo "Версии пакетов:"
rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}\n' \
    noctalia \
    umbriel-nightly \
    xdg-desktop-portal-umbriel-nightly \
    greetd \
    noctalia-greeter 2>/dev/null || true

echo
echo "Default target:"
systemctl get-default 2>/dev/null || true

echo
echo "Greeter:"
if systemctl is-active --quiet greetd.service 2>/dev/null; then
    echo "greetd активен"
elif systemctl is-enabled --quiet greetd.service 2>/dev/null; then
    echo "greetd включён, но не запущен"
else
    echo "greetd не включён"
fi

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
echo "Диагностика при чёрном экране:"
echo "sudo umbriel-diagnostics"

echo
echo "Резервные копии: $BACKUP"
echo "Журнал: $LOG"

echo
echo "ВАЖНО:"
echo "1. Umbriel и Noctalia Greeter установлены из Terra (сторонний репозиторий)."
echo "2. Noctalia и greetd установлены из официальных репозиториев Fedora."
echo "3. Проприетарный драйвер NVIDIA не устанавливался."
echo "4. VirtualBox Guest Additions устанавливаются вручную."
echo "5. Если экран чёрный: Ctrl+Alt+F3, затем sudo umbriel-diagnostics."
echo "6. Аварийный возврат в текстовый режим:"
echo "   sudo systemctl set-default multi-user.target"
echo "   sudo reboot"

echo
echo "=================================================="
