#!/usr/bin/env bash
# Debian 13 Trixie: Umbriel + Noctalia v5, with hardware-aware setup and interactive DM selection.
# The Noctalia APT repository is community-maintained; see https://docs.noctalia.dev/

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

VERSION="8.0.0"
LOG_FILE="/var/log/umbriel-noctalia-install.log"
BACKUP_DIR="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"
NOCTALIA_KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
NOCTALIA_SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"
NOCTALIA_SOURCES_FILE="/etc/apt/sources.list.d/noctalia-trixie.sources"
DM_SELECTION="auto"                  # auto | keep | noctalia-greeter | lightdm | sddm | gdm3 | ly | ...
SELECTED_DM="none"
LOCALE_OVERRIDE=""
TMP_DIR=""

APT_OPTS=(-y -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_SUSPEND=1

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Использование:
  sudo ./install-umbriel-noctalia-debian13-v8.sh [параметры]

Параметры:
  --with-greeter              Предварительно выбрать Noctalia Greeter (без интерактивного меню).
  --no-greeter                Оставить текущий Display Manager; если его нет — не устанавливать.
  --display-manager NAME      Выбрать: noctalia-greeter, lightdm, sddm, gdm3, ly или keep.
  --locale LOCALE             Принудительно задать системную локаль, например ru_RU.UTF-8.
  -h, --help                  Показать справку.

По умолчанию в конце установки будет показано меню Display Manager.
На системе без установленного DM потребуется выбрать один из доступных вариантов.
Текущая графическая среда и пользовательские конфиги не удаляются.
USAGE
}

while (($#)); do
  case "$1" in
    --with-greeter) DM_SELECTION=noctalia-greeter ;;
    --no-greeter) DM_SELECTION=keep ;;
    --display-manager)
      (($# >= 2)) || die "После --display-manager требуется имя."
      DM_SELECTION="$2"; shift ;;
    --replace-display-manager) warn "--replace-display-manager устарел: замена теперь подтверждается интерактивно." ;;
    --locale)
      (($# >= 2)) || die "После --locale требуется значение."
      LOCALE_OVERRIDE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Запустите скрипт через sudo."
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_CODENAME:-}" == trixie ]] || \
  die "Поддерживается Debian 13 Trixie. Обнаружено: ${PRETTY_NAME:-unknown}."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "Noctalia APT repository supports amd64/arm64, not $ARCH." ;; esac

# Resolve the desktop user. Do not install user configuration into /root when sudo is used.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then TARGET_USER="$(logname 2>/dev/null || true)"; fi
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /nologin|false/ {print $1; exit}')"
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Не удалось определить обычного пользователя. Запустите через sudo из пользовательской сессии."
getent passwd "$TARGET_USER" >/dev/null || die "Пользователь $TARGET_USER не существует."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_UID="$(id -u "$TARGET_USER")"
[[ -d "$TARGET_HOME" && "$TARGET_HOME" != / ]] || die "Некорректный HOME пользователя: $TARGET_HOME"

mkdir -p "$BACKUP_DIR"
info "Версия скрипта: $VERSION"
info "Система: ${PRETTY_NAME:-Debian} ($ARCH)"
info "Пользователь: $TARGET_USER ($TARGET_HOME)"
info "Резервные копии: $BACKUP_DIR"

# Detect virtualization, chassis and GPU independently: a VM can emulate a laptop/desktop chassis.
VIRT="none"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT="$(systemd-detect-virt --vm 2>/dev/null || true)"
  [[ -n "$VIRT" ]] || VIRT="none"
fi
CONTAINER="none"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  CONTAINER="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ -n "$CONTAINER" ]] || CONTAINER="none"
fi
CHASSIS="unknown"
if command -v hostnamectl >/dev/null 2>&1; then CHASSIS="$(hostnamectl chassis 2>/dev/null || true)"; fi
if [[ -z "$CHASSIS" || "$CHASSIS" == unknown ]] && [[ -r /sys/class/dmi/id/chassis_type ]]; then
  case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in
    8|9|10|14) CHASSIS="laptop" ;;
    3|4|5|6|7|15|16) CHASSIS="desktop" ;;
  esac
fi
HAS_BATTERY=0
for p in /sys/class/power_supply/*; do
  [[ -e "$p/type" ]] || continue
  [[ "$(cat "$p/type" 2>/dev/null || true)" == Battery ]] && HAS_BATTERY=1
 done
if [[ "$VIRT" != none || "$CONTAINER" != none ]]; then
  MACHINE_CLASS="virtual-machine"
elif [[ "$CHASSIS" == laptop || $HAS_BATTERY -eq 1 ]]; then
  MACHINE_CLASS="laptop"
elif [[ "$CHASSIS" == desktop ]]; then
  MACHINE_CLASS="desktop"
else
  MACHINE_CLASS="physical-unknown"
fi

GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
GPU_INTEL=0; GPU_AMD=0; GPU_NVIDIA=0
 grep -qi Intel <<<"$GPU_INFO" && GPU_INTEL=1 || true
 grep -qiE 'AMD|ATI' <<<"$GPU_INFO" && GPU_AMD=1 || true
 grep -qi NVIDIA <<<"$GPU_INFO" && GPU_NVIDIA=1 || true
info "Тип устройства: $MACHINE_CLASS; виртуализация: $VIRT; контейнер: $CONTAINER"
info "Видеоустройства: ${GPU_INFO:-не обнаружены через PCI}"
if [[ "$CONTAINER" != none ]]; then
  die "Установка графического стека внутри контейнера ($CONTAINER) не поддерживается. Запустите скрипт в полноценной Debian-системе или виртуальной машине."
fi
NETWORK_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'Network controller|Wireless|Ethernet controller' || true)"
info "Сетевые контроллеры: ${NETWORK_INFO:-не обнаружены через PCI}"

# Keep a copy of APT source files before any source changes.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ -f "$f" ]] || continue
  case "$f" in *noctalia*|*trixie-backports*) continue ;; esac
  cp -a -- "$f" "$BACKUP_DIR/$(basename "$f").$(echo "$f" | cksum | awk '{print $1}').bak"
done

# Disable only obsolete CD-ROM entries; preserve all network repositories.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [[ -f "$f" ]] || continue
  if grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' "$f"; then
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").cdrom.bak"
    sed -i -E 's/^([[:space:]]*deb[[:space:]]+)cdrom:/\1# cdrom:/' "$f"
  fi
done

apt-get "${APT_OPTS[@]}" update || die "apt-get update завершился ошибкой. Проверьте сетевые источники Debian."
apt-get "${APT_OPTS[@]}" install ca-certificates curl wget gnupg python3 pciutils usbutils locales xdg-user-dirs || \
  die "Не удалось установить базовые инструменты."

# Configure the official Debian archive components without replacing the user's source layout.
# non-free-firmware is needed for many Wi-Fi/GPU devices; add components only to Debian archive stanzas.
python3 - <<'PY'
from pathlib import Path
import re, shutil
files = [Path('/etc/apt/sources.list'), *Path('/etc/apt/sources.list.d').glob('*.sources'), *Path('/etc/apt/sources.list.d').glob('*.list')]
for p in files:
    if not p.is_file() or 'noctalia' in p.name or 'backports' in p.name: continue
    text = p.read_text(errors='replace')
    old = text
    if p.suffix == '.sources':
        blocks = re.split(r'(?=^Types:)', text, flags=re.M)
        out=[]
        for b in blocks:
            if re.search(r'^URIs:\s*https?://(?:deb|security).debian.org/', b, re.M) and re.search(r'^Suites:.*\b(?:trixie|stable|trixie-updates|trixie-security)\b', b, re.M):
                m=re.search(r'^Components:\s*(.*)$', b, re.M)
                if m:
                    comps=m.group(1).split()
                    for c in ('contrib','non-free','non-free-firmware'):
                        if c not in comps: comps.append(c)
                    b=b[:m.start(1)]+' '.join(comps)+b[m.end(1):]
            out.append(b)
        text=''.join(out)
    else:
        lines=[]
        for line in text.splitlines(True):
            if re.match(r'^\s*deb\s+', line) and re.search(r'https?://(?:deb|security).debian.org/', line):
                stripped=line.rstrip('\n')
                for c in ('contrib','non-free','non-free-firmware'):
                    if not re.search(rf'\s{re.escape(c)}(?:\s|$)', stripped): stripped += ' '+c
                line=stripped+'\n'
            lines.append(line)
        text=''.join(lines)
    if text != old:
        shutil.copy2(p, p.with_suffix(p.suffix+'.pre-umbriel.bak'))
        p.write_text(text)
PY

# Umbriel itself requires newer wlroots/DRM/input/XKB libraries from Debian Backports.
# Detect an existing trixie-backports entry before adding a new source to avoid duplicate indexes.
BACKPORTS_FILE="/etc/apt/sources.list.d/debian-trixie-backports.sources"
has_debian_backports_elsewhere() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]trixie-backports([[:space:]]|$)' "$f"; then
      return 0
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$BACKPORTS_FILE" ]] && continue
    if grep -Eq '^Suites:.*(^|[[:space:]])trixie-backports([[:space:]]|$)' "$f" && \
       grep -Eq '^URIs:.*https?://(deb\.)?debian\.org/' "$f"; then
      return 0
    fi
  done
  return 1
}

if has_debian_backports_elsewhere; then
  # A previous installer run may have created this file even though the user
  # already had Backports in sources.list. Back it up and remove that duplicate.
  if [[ -f "$BACKPORTS_FILE" ]] && \
     grep -Eq '^Suites:.*(^|[[:space:]])trixie-backports([[:space:]]|$)' "$BACKPORTS_FILE" && \
     grep -Eq '^URIs:.*https?://(deb\.)?debian\.org/' "$BACKPORTS_FILE"; then
    cp -a "$BACKPORTS_FILE" "$BACKUP_DIR/debian-trixie-backports.duplicate.sources.bak"
    rm -f "$BACKPORTS_FILE"
    info "Удалён дублирующий файл Debian Backports; исходная конфигурация сохранена в резервной копии."
  else
    info "Debian trixie-backports уже настроен; дополнительный источник не создаётся."
  fi
else
  if [[ ! -f "$BACKPORTS_FILE" ]]; then
    cat > "$BACKPORTS_FILE" <<'EOF_BACKPORTS'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_BACKPORTS
    info "Добавлен Debian trixie-backports для зависимостей Umbriel."
  else
    info "Используется существующий $BACKPORTS_FILE."
  fi
fi

# Install Noctalia's documented APT signing-key package and repository definition.
TMP_DIR="$(mktemp -d /tmp/noctalia-install.XXXXXX)"
wget --https-only --timeout=60 --tries=3 -q "$NOCTALIA_KEYRING_URL" -O "$TMP_DIR/noctalia-keyring.deb" || die "Не удалось скачать ключ Noctalia."
dpkg -i "$TMP_DIR/noctalia-keyring.deb" || die "Не удалось установить пакет ключа Noctalia."
wget --https-only --timeout=60 --tries=3 -q "$NOCTALIA_SOURCES_URL" -O "$TMP_DIR/noctalia.sources" || die "Не удалось скачать описание репозитория Noctalia."
install -m 0644 "$TMP_DIR/noctalia.sources" "$NOCTALIA_SOURCES_FILE"
if ! grep -qE "^Architectures:.*(^|[[:space:]])${ARCH}([[:space:]]|$)" "$NOCTALIA_SOURCES_FILE"; then
  die "Репозиторий Noctalia не публикует пакеты для $ARCH."
fi
apt-get "${APT_OPTS[@]}" update || die "Не удалось обновить индексы после подключения репозитория Noctalia."

# Required packages must be installed; optional extras are reported, never silently substituted.
# Install Umbriel separately with Backports as the target release. Its package
# depends on newer libdrm/libinput/libxkbcommon/wlroots than Debian stable ships.
info "Установка Umbriel и его зависимостей из Debian trixie-backports..."
if ! apt-get "${APT_OPTS[@]}" install -t trixie-backports umbriel; then
  warn "Не удалось разрешить зависимости Umbriel. Диагностика доступных версий:"
  apt-cache policy umbriel libdrm2 libinput10 libxkbcommon0 libwlroots-0.20 || true
  HELD_PACKAGES="$(apt-mark showhold 2>/dev/null || true)"
  if [[ -n "$HELD_PACKAGES" ]]; then
    warn "Обнаружены удерживаемые пакеты (apt-mark hold):"
    printf '%s\n' "$HELD_PACKAGES"
  fi
  die "Установка Umbriel из trixie-backports не удалась. Проверьте вывод apt-cache policy и удерживаемые пакеты."
fi

REQUIRED_PACKAGES=(
  dbus dbus-user-session libpam-systemd
  noctalia xdg-desktop-portal-umbriel
  xdg-desktop-portal xdg-desktop-portal-gtk
  polkitd pkexec mate-polkit mate-polkit-bin
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth
  network-manager bluez
  xwayland x11-utils x11-xserver-utils xauth xdg-utils
  kitty nautilus firefox-esr
  qtwayland5 qt6-wayland qt5ct qt6ct libqt5svg5 libqt6svg6
  gvfs gvfs-backends gvfs-fuse
  locales xdg-user-dirs
  libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers
  fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-noto-cjk fonts-liberation2
  adwaita-icon-theme papirus-icon-theme
  brightnessctl playerctl wl-clipboard
  gnome-keyring accountsservice upower power-profiles-daemon
  man-db sudo
)
info "Установка обязательных компонентов из согласованного набора Debian Trixie + trixie-backports..."
# Umbriel upgrades shared system libraries (notably libxkbcommon, Mesa and
# PipeWire) to Backports versions. Installing the rest from stable alone can
# request exact-version dependencies from stable and conflict with those upgrades.
# Use Backports as the target release for this complete transaction; packages
# absent from Backports still resolve from the normal configured repositories.
if ! apt-get "${APT_OPTS[@]}" install -t trixie-backports "${REQUIRED_PACKAGES[@]}"; then
  warn "Не удалось установить согласованный набор обязательных пакетов. Диагностика версий:"
  apt-cache policy \
    libpipewire-0.3-0t64 libpipewire-0.3-modules libspa-0.2-modules libspa-0.2-bluetooth \
    pipewire pipewire-alsa pipewire-bin wireplumber \
    libxkbcommon0 libxkbcommon-x11-0 libxkbregistry0 \
    mesa-libgallium mesa-va-drivers libgl1-mesa-dri mesa-vulkan-drivers \
    noctalia xdg-desktop-portal-umbriel || true
  HELD_PACKAGES="$(apt-mark showhold 2>/dev/null || true)"
  if [[ -n "$HELD_PACKAGES" ]]; then
    warn "Обнаружены удерживаемые пакеты (apt-mark hold):"
    printf '%s\n' "$HELD_PACKAGES"
  fi
  die "Не удалось установить остальные обязательные пакеты даже с trixie-backports. Umbriel уже устанавливался отдельным этапом."
fi

OPTIONAL_PACKAGES=(
  gnome-text-editor gnome-calculator mpv mpv-mpris wdisplays ddcutil
  fonts-noto-extra fonts-jetbrains-mono sound-theme-freedesktop
  qml-module-qtgraphicaleffects qml6-module-qt5compat-graphicaleffects
  qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window
  mesa-utils
)
AVAILABLE_OPTIONAL=()
for p in "${OPTIONAL_PACKAGES[@]}"; do
  candidate="$(LC_ALL=C apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != '(none)' ]] && AVAILABLE_OPTIONAL+=("$p") || warn "Необязательный пакет отсутствует в подключённых репозиториях: $p"
done
((${#AVAILABLE_OPTIONAL[@]} == 0)) || apt-get "${APT_OPTS[@]}" install "${AVAILABLE_OPTIONAL[@]}" || warn "Часть необязательных приложений не установлена."

# GPU-specific firmware and media packages.
FIRMWARE_PACKAGES=()
if ((GPU_INTEL)); then FIRMWARE_PACKAGES+=(firmware-intel-graphics intel-media-va-driver); fi
if ((GPU_AMD)); then FIRMWARE_PACKAGES+=(firmware-amd-graphics firmware-linux-nonfree); fi
if ((GPU_NVIDIA)); then
  FIRMWARE_PACKAGES+=(firmware-nvidia-graphics)
  warn "Обнаружена NVIDIA: проприетарный драйвер намеренно не устанавливается автоматически."
fi
if [[ "$VIRT" == vmware ]]; then FIRMWARE_PACKAGES+=(open-vm-tools open-vm-tools-desktop); fi
if [[ "$VIRT" == kvm || "$VIRT" == qemu ]]; then FIRMWARE_PACKAGES+=(qemu-guest-agent spice-vdagent); fi
if [[ "$VIRT" == oracle ]]; then FIRMWARE_PACKAGES+=(virtualbox-guest-utils); fi
if [[ "$VIRT" == microsoft ]]; then FIRMWARE_PACKAGES+=(hyperv-daemons); fi
if [[ -n "$NETWORK_INFO" ]]; then FIRMWARE_PACKAGES+=(firmware-iwlwifi firmware-realtek firmware-atheros firmware-mediatek); fi
if [[ "$MACHINE_CLASS" == laptop ]]; then FIRMWARE_PACKAGES+=(firmware-sof-signed brightnessctl); fi
if ((${#FIRMWARE_PACKAGES[@]})); then
  UNIQUE_FIRMWARE=(); declare -A SEEN_FW=()
  for p in "${FIRMWARE_PACKAGES[@]}"; do [[ ${SEEN_FW[$p]+x} ]] || { UNIQUE_FIRMWARE+=("$p"); SEEN_FW[$p]=1; }; done
  INSTALL_FW=()
  for p in "${UNIQUE_FIRMWARE[@]}"; do
    candidate="$(LC_ALL=C apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]] && INSTALL_FW+=("$p") || warn "Firmware/guest package недоступен: $p"
  done
  ((${#INSTALL_FW[@]} == 0)) || apt-get "${APT_OPTS[@]}" install "${INSTALL_FW[@]}" || warn "Не все firmware/guest packages установлены."
fi

# Locale: preserve the currently configured system language unless --locale is supplied.
CURRENT_LOCALE="${LOCALE_OVERRIDE:-}"
if [[ -z "$CURRENT_LOCALE" && -r /etc/default/locale ]]; then
  CURRENT_LOCALE="$(sed -n 's/^LANG=//p' /etc/default/locale | head -n1 | tr -d '\"')"
fi
if [[ -z "$CURRENT_LOCALE" ]]; then CURRENT_LOCALE="${LANG:-C.UTF-8}"; fi
[[ "$CURRENT_LOCALE" == C || "$CURRENT_LOCALE" == POSIX ]] && CURRENT_LOCALE="C.UTF-8"
if [[ "$CURRENT_LOCALE" != C.UTF-8 ]]; then
  if grep -qE "^${CURRENT_LOCALE}[[:space:]]+UTF-8$" /usr/share/i18n/SUPPORTED 2>/dev/null; then
    cp -a /etc/locale.gen "$BACKUP_DIR/locale.gen.bak" 2>/dev/null || true
    if ! grep -qE "^[[:space:]#]*${CURRENT_LOCALE}[[:space:]]+UTF-8$" /etc/locale.gen; then
      printf '%s UTF-8\n' "$CURRENT_LOCALE" >> /etc/locale.gen
    else
      sed -i -E "s/^[[:space:]#]*(${CURRENT_LOCALE}[[:space:]]+UTF-8)/\1/" /etc/locale.gen
    fi
    locale-gen "$CURRENT_LOCALE" || warn "Не удалось сгенерировать локаль $CURRENT_LOCALE."
    update-locale "LANG=$CURRENT_LOCALE" || warn "Не удалось записать системную локаль."
  else
    warn "Локаль $CURRENT_LOCALE отсутствует в /usr/share/i18n/SUPPORTED; оставляю C.UTF-8."
    CURRENT_LOCALE="C.UTF-8"
    update-locale LANG=C.UTF-8 || true
  fi
else
  update-locale LANG=C.UTF-8 || true
fi
info "Системная локаль: $CURRENT_LOCALE"
LANG_CODE="${CURRENT_LOCALE%%_*}"
if [[ "$CURRENT_LOCALE" != C.UTF-8 ]]; then
  LOCALE_EXTRAS=()
  for p in "firefox-esr-l10n-$LANG_CODE" "manpages-$LANG_CODE" "hunspell-$LANG_CODE" "aspell-$LANG_CODE"; do
    candidate="$(LC_ALL=C apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]] && LOCALE_EXTRAS+=("$p")
  done
  ((${#LOCALE_EXTRAS[@]} == 0)) || apt-get "${APT_OPTS[@]}" install "${LOCALE_EXTRAS[@]}" || warn "Не все дополнительные языковые пакеты установлены."
fi

# Detect current XKB settings for the Umbriel user config; use a safe US fallback only if unknown.
KEYBOARD_LAYOUTS="${KEYBOARD_LAYOUTS:-}"
KEYBOARD_OPTIONS="${KEYBOARD_OPTIONS:-}"
KEYBOARD_MODEL="${KEYBOARD_MODEL:-}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT:-}"
if command -v localectl >/dev/null 2>&1; then
  LOCALectl_STATUS="$(localectl status 2>/dev/null || true)"
  [[ -n "$KEYBOARD_LAYOUTS" ]] || KEYBOARD_LAYOUTS="$(sed -n 's/^ *X11 Layout: *//p' <<<"$LOCALectl_STATUS" | head -n1)"
  [[ -n "$KEYBOARD_OPTIONS" ]] || KEYBOARD_OPTIONS="$(sed -n 's/^ *X11 Options: *//p' <<<"$LOCALectl_STATUS" | head -n1)"
  [[ -n "$KEYBOARD_MODEL" ]] || KEYBOARD_MODEL="$(sed -n 's/^ *X11 Model: *//p' <<<"$LOCALectl_STATUS" | head -n1)"
  [[ -n "$KEYBOARD_VARIANT" ]] || KEYBOARD_VARIANT="$(sed -n 's/^ *X11 Variant: *//p' <<<"$LOCALectl_STATUS" | head -n1)"
fi
[[ "$KEYBOARD_LAYOUTS" == "(none)" ]] && KEYBOARD_LAYOUTS=""
[[ "$KEYBOARD_OPTIONS" == "(none)" ]] && KEYBOARD_OPTIONS=""
[[ "$KEYBOARD_MODEL" == "(none)" ]] && KEYBOARD_MODEL=""
[[ "$KEYBOARD_VARIANT" == "(none)" ]] && KEYBOARD_VARIANT=""
[[ -n "$KEYBOARD_LAYOUTS" ]] || KEYBOARD_LAYOUTS=us
[[ -n "$KEYBOARD_MODEL" ]] || KEYBOARD_MODEL=pc105

# Copy the packaged upstream example, then add our settings as a separate optional include.
# This avoids inventing a full Umbriel config and keeps upstream defaults/actions intact.
USER_CONFIG_DIR="$TARGET_HOME/.config/umbriel"
USER_CONFIG="$USER_CONFIG_DIR/config.toml"
INTEGRATION_CONFIG="$USER_CONFIG_DIR/noctalia-integration.toml"
mkdir -p "$USER_CONFIG_DIR"
if [[ ! -e "$USER_CONFIG" ]]; then
  [[ -r /usr/share/umbriel/config.toml ]] || die "Не найден /usr/share/umbriel/config.toml из пакета Umbriel."
  install -m 0644 -o "$TARGET_USER" -g "$TARGET_GROUP" /usr/share/umbriel/config.toml "$USER_CONFIG"
  info "Создан пользовательский config.toml из штатного примера Umbriel."
else
  cp -a "$USER_CONFIG" "$BACKUP_DIR/umbriel-config.toml.bak"
  info "Существующий config.toml сохранён; обновляется только отдельный include-файл."
fi
cp -a "$USER_CONFIG" "$BACKUP_DIR/umbriel-config-before-include.toml"
if [[ -e "$INTEGRATION_CONFIG" ]]; then cp -a "$INTEGRATION_CONFIG" "$BACKUP_DIR/noctalia-integration.toml.bak"; fi

TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" USER_CONFIG="$USER_CONFIG" INTEGRATION_CONFIG="$INTEGRATION_CONFIG" \
KEYBOARD_LAYOUTS="$KEYBOARD_LAYOUTS" KEYBOARD_OPTIONS="$KEYBOARD_OPTIONS" KEYBOARD_MODEL="$KEYBOARD_MODEL" KEYBOARD_VARIANT="$KEYBOARD_VARIANT" \
python3 - <<'PY'
import json, os, re, shutil, tomllib
from pathlib import Path
cfg=Path(os.environ['USER_CONFIG'])
inc=Path(os.environ['INTEGRATION_CONFIG'])
raw=cfg.read_text()
try:
    parsed=tomllib.loads(raw)
except Exception as e:
    raise SystemExit(f'Конфигурация Umbriel не является корректным TOML; не изменяю её: {e}')

# Keep existing autostart entries while ensuring Noctalia starts with the compositor.
autostart=parsed.get('general',{}).get('autostart',[])
if not isinstance(autostart,list) or not all(isinstance(x,str) for x in autostart):
    raise SystemExit('general.autostart имеет неожиданный тип; конфигурация оставлена без изменений.')
if 'mate-polkit' not in autostart: autostart.append('mate-polkit')
if 'noctalia' not in autostart: autostart.append('noctalia')

layout=os.environ['KEYBOARD_LAYOUTS']; options=os.environ['KEYBOARD_OPTIONS']
model=os.environ['KEYBOARD_MODEL']; variant=os.environ['KEYBOARD_VARIANT']
for name,value in [('layout',layout),('options',options),('model',model),('variant',variant)]:
    if not re.fullmatch(r'[A-Za-z0-9_,:+-]*', value):
        raise SystemExit(f'Недопустимое значение XKB {name}: {value!r}')

lines=['# Managed by install-umbriel-noctalia-debian13-v7.sh.', '# Edit this file to customize the installer-provided integration.', '', '[general]', 'autostart = '+json.dumps(autostart,ensure_ascii=False), '', '[input.keyboard]', 'layout = '+json.dumps(layout), 'model = '+json.dumps(model), 'variant = '+json.dumps(variant), 'options = '+json.dumps(options), '', '[keybinds]',
       '"Mod+E" = "spawn nautilus"',
       '"Mod+B" = "spawn firefox-esr"',
       '"Mod+Shift+C" = "spawn noctalia msg panel-toggle control-center"',
       '"XF86AudioRaiseVolume" = "spawn noctalia msg volume-up"',
       '"XF86AudioLowerVolume" = "spawn noctalia msg volume-down"',
       '"XF86AudioMute" = "spawn noctalia msg volume-mute"',
       '"XF86MonBrightnessUp" = "spawn noctalia msg brightness-up"',
       '"XF86MonBrightnessDown" = "spawn noctalia msg brightness-down"', '']
inc.write_text('\n'.join(lines))

relative=inc.name
include=parsed.get('include',{}).get('optional',{})
files=include.get('files',[])
if not isinstance(files,list) or not all(isinstance(x,str) for x in files):
    raise SystemExit('include.optional.files имеет неожиданный формат; не изменяю основной конфиг.')
if relative not in files: files.append(relative)
array='files = '+json.dumps(files,ensure_ascii=False)
pattern=r'(?ms)^\[include\.optional\][ \t]*\n(.*?)(?=^\[|\Z)'
m=re.search(pattern,raw)
if m:
    block=m.group(1)
    fm=re.search(r'(?m)^files\s*=\s*\[[^\]]*\]\s*$',block)
    if fm:
        block=block[:fm.start()]+array+'\n'+block[fm.end():]
    else:
        block=array+'\n'+block
    raw=raw[:m.start(1)]+block+raw[m.end(1):]
else:
    raw=raw.rstrip()+'\n\n[include.optional]\n'+array+'\n'
# Validate the resulting TOML before replacing the active config.
tomllib.loads(raw)
cfg.write_text(raw)
PY
chown -R "$TARGET_USER:$TARGET_GROUP" "$USER_CONFIG_DIR"
chmod 0644 "$USER_CONFIG" "$INTEGRATION_CONFIG"

# Kitty configuration is kept in a separate include file; existing user settings are not replaced.
KITTY_DIR="$TARGET_HOME/.config/kitty"
KITTY_CONF="$KITTY_DIR/kitty.conf"
KITTY_EXTRA="$KITTY_DIR/umbriel-noctalia.conf"
mkdir -p "$KITTY_DIR"
cat > "$KITTY_EXTRA" <<'EOF_KITTY'
# Managed by Umbriel + Noctalia installer.
font_family JetBrains Mono
font_size 12.0
background_opacity 0.90
cursor_trail 1
window_padding_width 10
confirm_os_window_close 0
map ctrl+shift+c copy_to_clipboard
map ctrl+shift+v paste_from_clipboard
EOF_KITTY
if [[ ! -e "$KITTY_CONF" ]]; then
  printf 'include %s\n' "$KITTY_EXTRA" > "$KITTY_CONF"
elif ! grep -Fq 'umbriel-noctalia.conf' "$KITTY_CONF"; then
  cp -a "$KITTY_CONF" "$BACKUP_DIR/kitty.conf.bak"
  printf '\n# >>> Umbriel + Noctalia managed include >>>\ninclude %s\n# <<< Umbriel + Noctalia managed include <<<\n' "$KITTY_EXTRA" >> "$KITTY_CONF"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$KITTY_DIR"

# User directory names follow the selected locale. Migrate only known standard folder names,
# only when the localized destination does not exist; never merge or overwrite user data.
USER_DIRS_FILE="$TARGET_HOME/.config/user-dirs.dirs"
USER_DIRS_TMP="$(mktemp /tmp/umbriel-user-dirs.XXXXXX)"
if [[ -f "$USER_DIRS_FILE" ]]; then cp -a "$USER_DIRS_FILE" "$BACKUP_DIR/user-dirs.dirs.bak"; fi
if runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" LANG="$CURRENT_LOCALE" LANGUAGE="$CURRENT_LOCALE" \
  LC_ALL="$CURRENT_LOCALE" XDG_CONFIG_HOME="$TARGET_HOME/.config" \
  xdg-user-dirs-update --dummy-output "$USER_DIRS_TMP" --force; then
  python3 - "$USER_DIRS_FILE" "$USER_DIRS_TMP" "$TARGET_HOME" <<'PY_MIGRATE'
import os, re, sys
from pathlib import Path
old_file, new_file, home_arg = map(Path, sys.argv[1:])
home = home_arg.resolve()
known = {
 'DESKTOP': {'Desktop', 'Рабочий стол'},
 'DOWNLOAD': {'Downloads', 'Загрузки'},
 'TEMPLATES': {'Templates', 'Шаблоны'},
 'PUBLICSHARE': {'Public', 'Общедоступные'},
 'DOCUMENTS': {'Documents', 'Документы'},
 'MUSIC': {'Music', 'Музыка'},
 'PICTURES': {'Pictures', 'Изображения'},
 'VIDEOS': {'Videos', 'Видео'},
}
def parse(path):
    result={}
    if not path.is_file(): return result
    for line in path.read_text(errors='replace').splitlines():
        m=re.match(r'^XDG_([A-Z]+)_DIR="([^"]*)"$', line.strip())
        if m:
            value=m.group(2).replace('$HOME', str(home)).replace('\\"','"')
            result[m.group(1)]=Path(os.path.expanduser(value))
    return result
old=parse(old_file); new=parse(new_file)
for key, src in old.items():
    dst=new.get(key)
    if dst is None or src == dst: continue
    try:
        src_abs=src.resolve(strict=True)
    except FileNotFoundError:
        continue
    if src.is_symlink() or src_abs.parent != home or src_abs.name not in known.get(key,set()):
        continue
    if dst.parent.resolve() != home: continue
    if dst.exists() or dst.is_symlink():
        print(f'[WARN] Не переношу {src_abs}: каталог назначения уже существует: {dst}')
        continue
    try:
        os.rename(src_abs, dst)
        print(f'[INFO] Переименован пользовательский каталог: {src_abs.name} -> {dst.name}')
    except OSError as e:
        print(f'[WARN] Не удалось переименовать {src_abs}: {e}')
PY_MIGRATE
else
  warn "Не удалось подготовить локализованные XDG-каталоги; использую штатное обновление."
fi
rm -f "$USER_DIRS_TMP"
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" LANG="$CURRENT_LOCALE" LANGUAGE="$CURRENT_LOCALE" \
  LC_ALL="$CURRENT_LOCALE" XDG_CONFIG_HOME="$TARGET_HOME/.config" xdg-user-dirs-update --force || \
  warn "Не удалось обновить XDG-каталоги. Проверьте ~/.config/user-dirs.dirs."

# Ensure essential services are enabled without forcibly stopping an existing network stack.
if [[ -d /run/systemd/system ]]; then
  systemctl enable NetworkManager.service >/dev/null 2>&1 || warn "Не удалось включить NetworkManager."
  systemctl enable bluetooth.service >/dev/null 2>&1 || warn "Не удалось включить Bluetooth."
  systemctl enable power-profiles-daemon.service >/dev/null 2>&1 || true
else
  warn "systemd не запущен; службы NetworkManager/Bluetooth не включались."
fi

# Validate Umbriel using the real target user's home, but do not fake XDG_RUNTIME_DIR.
if ! runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" \
  umbriel config validate; then
  warn "umbriel config validate завершился ошибкой. Greeter не будет активирован автоматически."
  UMBRIEL_VALID=0
else
  UMBRIEL_VALID=1
fi

# Detect the currently selected Display Manager after the desktop packages are installed.
CURRENT_DM_TARGET="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
CURRENT_DM_UNIT=""
[[ -n "$CURRENT_DM_TARGET" ]] && CURRENT_DM_UNIT="$(basename "$CURRENT_DM_TARGET")"
CURRENT_DM_NAME=""
case "$CURRENT_DM_UNIT" in
  greetd.service) CURRENT_DM_NAME="greetd (текущий greeter определяется конфигурацией)" ;;
  lightdm.service) CURRENT_DM_NAME="LightDM" ;;
  sddm.service) CURRENT_DM_NAME="SDDM" ;;
  gdm3.service) CURRENT_DM_NAME="GDM3" ;;
  ly.service) CURRENT_DM_NAME="Ly" ;;
  lxdm.service) CURRENT_DM_NAME="LXDM" ;;
  slim.service) CURRENT_DM_NAME="SLiM" ;;
  xdm.service) CURRENT_DM_NAME="XDM" ;;
esac

# If there is no display-manager.service symlink, check enabled units and installed DM packages.
if [[ -z "$CURRENT_DM_UNIT" ]]; then
  for pair in 'greetd:greetd.service' 'lightdm:lightdm.service' 'sddm:sddm.service' 'gdm3:gdm3.service' 'ly:ly.service' 'lxdm:lxdm.service' 'slim:slim.service' 'xdm:xdm.service'; do
    pkg="${pair%%:*}"; unit="${pair#*:}"
    if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed && \
       systemctl is-enabled "$unit" >/dev/null 2>&1; then
      CURRENT_DM_UNIT="$unit"
      CURRENT_DM_NAME="$pkg (enabled)"
      break
    fi
  done
fi

INSTALLED_DM_PACKAGES=()
for pkg in greetd lightdm sddm gdm3 ly lxdm slim xdm; do
  if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
    INSTALLED_DM_PACKAGES+=("$pkg")
  fi
done
if [[ -n "$CURRENT_DM_UNIT" ]]; then
  info "Текущий Display Manager: ${CURRENT_DM_NAME:-$CURRENT_DM_UNIT}"
elif ((${#INSTALLED_DM_PACKAGES[@]})); then
  info "Найдены установленные, но не выбранные/не активированные DM: ${INSTALLED_DM_PACKAGES[*]}"
  info "В меню можно выбрать один из них, чтобы включить его как основной."
else
  info "Display Manager не обнаружен. Похоже, это чистая система без менеджера входа."
fi

# Build the menu only from packages available for this Debian release/architecture.
DM_IDS=()
DM_LABELS=()
DM_PACKAGES=()
DM_UNITS=()
add_dm_option() {
  local id="$1" label="$2" packages="$3" unit="$4" package candidate
  for package in $packages; do
    candidate="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
      warn "Вариант $label пропущен: пакет $package недоступен в подключённых репозиториях."
      return 0
    fi
  done
  DM_IDS+=("$id"); DM_LABELS+=("$label"); DM_PACKAGES+=("$packages"); DM_UNITS+=("$unit")
  return 0
}
add_dm_option noctalia-greeter "Noctalia Greeter (greetd, Wayland)" "noctalia-greeter greetd" "greetd.service"
add_dm_option sddm "SDDM (универсальный, X11/Wayland)" "sddm" "sddm.service"
add_dm_option gdm3 "GDM3 (GNOME Display Manager)" "gdm3" "gdm3.service"
add_dm_option lightdm "LightDM (лёгкий, преимущественно X11)" "lightdm lightdm-gtk-greeter" "lightdm.service"
add_dm_option ly "Ly (текстовый TUI login manager)" "ly" "ly.service"
add_dm_option lxdm "LXDM (X11)" "lxdm" "lxdm.service"
add_dm_option slim "SLiM (устаревший X11 login manager)" "slim" "slim.service"
add_dm_option xdm "XDM (базовый X11 login manager)" "xdm" "xdm.service"

# Resolve selection. In a normal terminal session ask at the end; explicit CLI options are supported for automation.
if [[ "$DM_SELECTION" == auto ]]; then
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '\n============================================================\n' > /dev/tty
    printf 'ВЫБОР DISPLAY MANAGER\n' > /dev/tty
    if [[ -n "$CURRENT_DM_UNIT" ]]; then
      printf 'Текущий: %s (%s)\n' "$CURRENT_DM_NAME" "$CURRENT_DM_UNIT" > /dev/tty
      printf '  0) Оставить текущий Display Manager без изменений\n' > /dev/tty
    else
      printf 'Текущий Display Manager не найден. Выберите, что установить.\n' > /dev/tty
    fi
    for i in "${!DM_IDS[@]}"; do
      printf '  %d) %s\n' "$((i+1))" "${DM_LABELS[$i]}" > /dev/tty
    done
    printf '  q) Пропустить установку Display Manager\n' > /dev/tty
    while true; do
      printf 'Ваш выбор: ' > /dev/tty
      IFS= read -r answer < /dev/tty || answer=q
      if [[ "$answer" == q || "$answer" == Q ]]; then DM_SELECTION=skip; break; fi
      if [[ "$answer" == 0 && -n "$CURRENT_DM_UNIT" ]]; then DM_SELECTION=keep; break; fi
      if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#DM_IDS[@]})); then
        DM_SELECTION="${DM_IDS[$((answer-1))]}"; break
      fi
      printf 'Неверный выбор. Повторите ввод.\n' > /dev/tty
    done
  else
    if [[ -n "$CURRENT_DM_UNIT" ]]; then
      warn "Нет интерактивного терминала; сохраняю текущий Display Manager. Для выбора используйте --display-manager NAME."
      DM_SELECTION=keep
    else
      die "Display Manager не установлен, а интерактивный терминал недоступен. Запустите скрипт из терминала или укажите --display-manager NAME."
    fi
  fi
fi

if [[ "$DM_SELECTION" == skip ]]; then
  SELECTED_DM="none"
  warn "Установка Display Manager пропущена. После перезагрузки вход будет доступен только через TTY, если другой DM не настроен."
elif [[ "$DM_SELECTION" == keep ]]; then
  SELECTED_DM="${CURRENT_DM_NAME:-none (оставлен без изменений)}"
  if [[ -z "$CURRENT_DM_UNIT" ]]; then
    warn "Текущий Display Manager отсутствует; оставлена консольная загрузка."
  else
    info "Оставляю текущий Display Manager: $CURRENT_DM_NAME"
  fi
else
  SELECTED_INDEX=-1
  for i in "${!DM_IDS[@]}"; do
    [[ "${DM_IDS[$i]}" == "$DM_SELECTION" ]] && SELECTED_INDEX="$i" && break
  done
  ((SELECTED_INDEX >= 0)) || die "Неизвестный или недоступный Display Manager: $DM_SELECTION. Используйте --help."
  SELECTED_PACKAGES="${DM_PACKAGES[$SELECTED_INDEX]}"
  SELECTED_UNIT="${DM_UNITS[$SELECTED_INDEX]}"
  SELECTED_LABEL="${DM_LABELS[$SELECTED_INDEX]}"

  if [[ "$SELECTED_UNIT" == greetd.service ]]; then
    [[ "$UMBRIEL_VALID" == 1 ]] || die "Umbriel config не прошёл проверку; Noctalia Greeter не будет активирован."
    info "Установка Noctalia Greeter из Debian Trixie Backports..."
    apt-get "${APT_OPTS[@]}" install -t trixie-backports greetd noctalia-greeter || die "Не удалось установить greetd/noctalia-greeter из trixie-backports."
    command -v noctalia-greeter-session >/dev/null 2>&1 || die "После установки не найдена команда noctalia-greeter-session."
    if [[ ! -f /etc/greetd/config.toml ]] || ! grep -q 'noctalia-greeter-session' /etc/greetd/config.toml; then
      die "В /etc/greetd/config.toml не обнаружен noctalia-greeter-session. Проверьте конфигурацию пакета; greetd не включён."
    fi
    if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
      noctalia-greeter-apply-appearance --setup-system || warn "Не удалось инициализировать настройки Noctalia Greeter."
    fi
  else
    info "Установка $SELECTED_LABEL..."
    read -r -a SELECTED_PACKAGE_ARRAY <<< "$SELECTED_PACKAGES"
    apt-get "${APT_OPTS[@]}" install "${SELECTED_PACKAGE_ARRAY[@]}" || die "Не удалось установить $SELECTED_LABEL."
  fi

  if [[ -n "$CURRENT_DM_UNIT" && "$CURRENT_DM_UNIT" != "$SELECTED_UNIT" ]]; then
    info "Отключаю прежний Display Manager $CURRENT_DM_UNIT (пакет и конфиги не удаляются)."
    systemctl disable "$CURRENT_DM_UNIT" || warn "Не удалось отключить старую службу $CURRENT_DM_UNIT."
  fi
  if [[ -d /run/systemd/system ]]; then
    systemctl enable "$SELECTED_UNIT" || die "Не удалось включить $SELECTED_UNIT."
    systemctl set-default graphical.target || warn "Не удалось установить graphical.target."
  else
    warn "systemd не запущен: служба $SELECTED_UNIT не включена."
  fi
  SELECTED_DM="$SELECTED_LABEL"
  info "Выбран Display Manager: $SELECTED_DM"
fi

# Final checks and report.
info "Проверка установленных пакетов..."
for p in umbriel noctalia xdg-desktop-portal-umbriel kitty nautilus firefox-esr qtwayland5 qt6-wayland qt5ct qt6ct xwayland; do
  dpkg-query -W -f='${db:Status-Status} ${Version}\n' "$p" 2>/dev/null || warn "Пакет не найден: $p"
done

cat <<REPORT

============================================================
УСТАНОВКА ЗАВЕРШЕНА (скрипт $VERSION)
============================================================
Система:       ${PRETTY_NAME:-Debian}
Архитектура:   $ARCH
Устройство:    $MACHINE_CLASS
Виртуализация: $VIRT
GPU:
${GPU_INFO:-  не обнаружен}
Пользователь:  $TARGET_USER
Локаль:        $CURRENT_LOCALE
XKB layout:    $KEYBOARD_LAYOUTS
Display Manager: $SELECTED_DM

Umbriel config:       $USER_CONFIG
Noctalia integration: $INTEGRATION_CONFIG
Kitty config:         $KITTY_CONF
Backup:               $BACKUP_DIR
Log:                  $LOG_FILE

Основные сочетания:
Super+Enter  — Kitty (стандартное сочетание Umbriel)
Super        — Launcher Noctalia (стандартное сочетание Umbriel)
Super+E      — Nautilus
Super+B      — Firefox ESR
Super+Shift+C — Control Center Noctalia
PolicyKit — mate-polkit agent запускается вместе с Umbriel

X11-приложения запускаются через XWayland. Отдельный Xorg-сервер
не устанавливается: для сессии Wayland он обычно не требуется.

Перед перезагрузкой проверьте:
  umbriel config validate
  ls -l /usr/share/wayland-sessions/
  systemctl status display-manager.service   # выбранный Display Manager
============================================================
REPORT
