#!/usr/bin/env bash
# Umbriel + Noctalia installer for Debian 13 (Trixie)
# Conservative installer: no repository edits, no network-manager takeover,
# no blanket service disabling, no autoremove, and no user config overwrite.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_VERSION='1.0.0'
PROGRAM=${0##*/}
MODE=''
VERBOSE=0
ENABLE_BLUETOOTH=0
ENABLE_VM_INTEGRATION=0
TARGET_USER=''
LOG_FILE=''
BACKUP_DIR=''

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
err(){ printf '[ERROR] %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
debug(){ (( VERBOSE )) && printf '[DEBUG] %s\n' "$*" || true; }

usage(){ cat <<EOF
$PROGRAM $SCRIPT_VERSION — Debian 13 Trixie

Использование:
  $PROGRAM --report [--verbose]
  sudo $PROGRAM --dry-run [параметры]
  sudo $PROGRAM --install [параметры]

Режимы:
  --report                  Только диагностика, без изменений (режим по умолчанию).
  --dry-run                 Проверка APT-кандидатов и симуляция установки.
  --install                 Установить Umbriel + Noctalia + Greeter.

Параметры:
  --enable-bluetooth        Установить BlueZ и Bluetooth-модуль PipeWire;
                            без параметра Bluetooth не включается принудительно.
  --enable-vm-integration   Добавить гостевые компоненты только для обнаруженной VM.
  --user USER               Пользовательский аккаунт для проверки домашнего каталога.
  --verbose                 Подробный журнал.
  -h, --help                Справка.

Ограничения безопасности:
  • Только Debian 13 Trixie, amd64/arm64.
  • Репозитории и APT-приоритеты не изменяются.
  • Не выполняются autoremove, full-upgrade, сетевые перенастройки и массовое
    отключение служб.
  • Существующий display manager не отключается автоматически.
  • Перед изменениями /etc/greetd и пользовательские файлы копируются в backup.
  • При конфликте с другим display manager установка останавливается.
EOF
}

while (($#)); do
  case "$1" in
    --report) [[ -z "$MODE" ]] || die 'Укажите только один режим.'; MODE=report ;;
    --dry-run) [[ -z "$MODE" ]] || die 'Укажите только один режим.'; MODE=dry-run ;;
    --install) [[ -z "$MODE" ]] || die 'Укажите только один режим.'; MODE=install ;;
    --enable-bluetooth) ENABLE_BLUETOOTH=1 ;;
    --enable-vm-integration) ENABLE_VM_INTEGRATION=1 ;;
    --verbose) VERBOSE=1 ;;
    --user)
      (($# >= 2)) || die 'После --user укажите имя пользователя.'
      TARGET_USER=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
  shift
done
MODE=${MODE:-report}

for c in awk bash dpkg dpkg-query grep sed uname; do command -v "$c" >/dev/null 2>&1 || die "Не найдена команда $c."; done
[[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || die "Поддерживается только Debian 13 Trixie; обнаружено: ${PRETTY_NAME:-unknown}."
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64|arm64) ;; *) die "Архитектура $ARCH не поддерживается этим выпуском." ;; esac

if [[ $MODE != report ]]; then
  [[ $EUID -eq 0 ]] || die 'Для --dry-run и --install запустите скрипт через sudo.'
  command -v apt-get >/dev/null 2>&1 || die 'Не найден apt-get.'
  command -v apt-cache >/dev/null 2>&1 || die 'Не найден apt-cache.'
fi

if [[ -z "$TARGET_USER" ]]; then
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then TARGET_USER=$SUDO_USER
  elif [[ $EUID -ne 0 ]]; then TARGET_USER=$(id -un)
  fi
fi
if [[ -n "$TARGET_USER" ]]; then
  getent passwd "$TARGET_USER" >/dev/null 2>&1 || die "Пользователь '$TARGET_USER' не найден."
  TARGET_HOME=$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Домашний каталог пользователя '$TARGET_USER' не найден."
else
  TARGET_HOME=''
fi

VIRT=none; CONTAINER=none; CHASSIS=unknown
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt --vm 2>/dev/null || true); VIRT=${VIRT:-none}
  CONTAINER=$(systemd-detect-virt --container 2>/dev/null || true); CONTAINER=${CONTAINER:-none}
fi
if command -v hostnamectl >/dev/null 2>&1; then CHASSIS=$(hostnamectl chassis 2>/dev/null || true); fi
[[ -n "$CHASSIS" ]] || CHASSIS=unknown
HAS_BATTERY=0
for p in /sys/class/power_supply/*; do
  [[ -r "$p/type" ]] || continue
  [[ $(<"$p/type") == Battery ]] && HAS_BATTERY=1
 done
PCI_LIST=''; USB_LIST=''
command -v lspci >/dev/null 2>&1 && PCI_LIST=$(lspci -nn 2>/dev/null || true)
command -v lsusb >/dev/null 2>&1 && USB_LIST=$(lsusb 2>/dev/null || true)
GPU_INFO=$(grep -Ei 'VGA compatible controller|3D controller|Display controller' <<<"$PCI_LIST" || true)
NETWORK_INFO=$(grep -Ei 'Ethernet controller|Network controller|Wireless' <<<"$PCI_LIST" || true)
AUDIO_INFO=$(grep -Ei 'Audio device|Multimedia audio controller' <<<"$PCI_LIST" || true)

# Wi-Fi is detected from wireless sysfs interfaces, not generic PCI network controllers.
HAS_WIFI=0
for p in /sys/class/net/*; do
  [[ -e "$p/wireless" || -e "$p/phy80211" ]] && HAS_WIFI=1
 done
if (( ! HAS_WIFI )) && command -v iw >/dev/null 2>&1; then
  iw dev 2>/dev/null | grep -q 'Interface ' && HAS_WIFI=1 || true
fi
HAS_BT=0
for p in /sys/class/bluetooth/*; do [[ -e "$p" ]] && HAS_BT=1; done

CONNECTED_DRM=0
for p in /sys/class/drm/*/status; do
  [[ -r "$p" ]] || continue
  [[ $(<"$p") == connected ]] && CONNECTED_DRM=$((CONNECTED_DRM+1))
 done
NETWORK_STACK=unknown
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then NETWORK_STACK=NetworkManager-active
  elif systemctl is-active --quiet networking.service 2>/dev/null; then NETWORK_STACK=networking-service-active
  elif [[ -f /etc/network/interfaces ]]; then NETWORK_STACK=ifupdown-config-present
  fi
fi

printf '\n============================================================\n'
printf 'UMBRIEL + NOCTALIA INSTALLER %s\n' "$SCRIPT_VERSION"
printf 'MODE: %s\nOS: %s\nARCH: %s\nKERNEL: %s\n' "$MODE" "${PRETTY_NAME:-Debian}" "$ARCH" "$(uname -r)"
printf 'VIRTUALIZATION: %s\nCONTAINER: %s\nCHASSIS: %s\n' "$VIRT" "$CONTAINER" "$CHASSIS"
printf 'BATTERY: %s\nWI-FI: %s\nBLUETOOTH: %s\n' "$([[ $HAS_BATTERY == 1 ]] && echo PRESENT || echo NOT-DETECTED)" "$([[ $HAS_WIFI == 1 ]] && echo PRESENT || echo NOT-DETECTED)" "$([[ $HAS_BT == 1 ]] && echo PRESENT || echo NOT-DETECTED)"
printf 'NETWORK STACK: %s\nCONNECTED DRM OUTPUTS: %s\n' "$NETWORK_STACK" "$CONNECTED_DRM"
printf '\nGPU:\n%s\nNETWORK:\n%s\nAUDIO:\n%s\n' "${GPU_INFO:-Not detected}" "${NETWORK_INFO:-Not detected}" "${AUDIO_INFO:-Not detected}"
if [[ -n "$TARGET_USER" ]]; then printf '\nTARGET USER: %s\nHOME: %s\n' "$TARGET_USER" "$TARGET_HOME"; fi
if command -v systemctl >/dev/null 2>&1; then
  printf '\nDISPLAY / CORE SERVICES:\n'
  for u in greetd.service display-manager.service NetworkManager.service networking.service bluetooth.service; do
    a=$(systemctl is-active "$u" 2>/dev/null || true); e=$(systemctl is-enabled "$u" 2>/dev/null || true)
    printf '  %-34s active=%-10s enabled=%s\n' "$u" "${a:-unknown}" "${e:-unknown}"
  done
fi

[[ "$MODE" == report ]] && { printf '\nREPORT COMPLETE; no changes made.\n'; exit 0; }

# Must have an actual interactive user for a graphical desktop installation.
[[ -n "$TARGET_USER" ]] || die 'Не удалось определить обычного пользователя. Запустите через sudo или укажите --user USER.'
[[ $(id -u "$TARGET_USER") -ne 0 ]] || die 'Целевой пользователь не должен быть root.'

# Refuse unsupported container install and avoid modifying a container host.
[[ "$CONTAINER" == none ]] || die "Обнаружен контейнер '$CONTAINER'. Установка графического сеанса в контейнер не поддерживается."

# Package set. Do not add NetworkManager, firmware bundles, Qt/QML, or power managers blindly.
PACKAGES=(
  umbriel noctalia noctalia-greeter greetd
  dbus dbus-user-session libpam-systemd
  xdg-desktop-portal xdg-desktop-portal-umbriel xdg-desktop-portal-gtk
  python3
  polkitd mate-polkit
  pipewire pipewire-audio pipewire-pulse wireplumber
  xwayland xdg-utils xdg-user-dirs kitty
  fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-noctalia-tabler
)
REASONS=('Base: Umbriel, Noctalia, Greeter, portals, PolicyKit, PipeWire, XWayland and basic desktop utilities')

if (( ENABLE_BLUETOOTH )); then
  PACKAGES+=(bluez libspa-0.2-bluetooth)
  REASONS+=('Bluetooth explicitly requested by operator')
elif (( HAS_BT )); then
  PACKAGES+=(bluez libspa-0.2-bluetooth)
  REASONS+=('Bluetooth adapter detected in /sys/class/bluetooth')
fi

if (( ENABLE_VM_INTEGRATION )); then
  case "$VIRT" in
    qemu|kvm)
      [[ ! -e /dev/virtio-ports/com.redhat.spice.0 ]] || PACKAGES+=(spice-vdagent)
      [[ ! -e /dev/virtio-ports/org.qemu.guest_agent.0 ]] || PACKAGES+=(qemu-guest-agent)
      ;;
    vmware) PACKAGES+=(open-vm-tools) ;;
    oracle) PACKAGES+=(virtualbox-guest-utils) ;;
    none) warn 'Флаг VM integration указан, но гипервизор не обнаружен.' ;;
    *) warn "Для гипервизора '$VIRT' автоматический пакет не выбран." ;;
  esac
fi

# Deduplicate package list.
UNIQUE=(); declare -A SEEN=()
for p in "${PACKAGES[@]}"; do [[ ${SEEN[$p]+yes} ]] && continue; SEEN[$p]=1; UNIQUE+=("$p"); done

# Validate an existing Umbriel TOML configuration before any package transaction.
EXISTING_UMBRIEL_CONFIG="$TARGET_HOME/.config/umbriel/config.toml"
if [[ -f "$EXISTING_UMBRIEL_CONFIG" ]]; then
  command -v python3 >/dev/null 2>&1 || die 'Для проверки существующего TOML нужен python3.'
  python3 - "$EXISTING_UMBRIEL_CONFIG" <<'PY_PREFLIGHT'
import sys, tomllib
from pathlib import Path
p=Path(sys.argv[1])
try:
    data=tomllib.loads(p.read_text())
except Exception as exc:
    raise SystemExit(f'Существующий Umbriel config.toml не проходит TOML-проверку: {exc}')
general=data.get('general', {})
if not isinstance(general, dict):
    raise SystemExit('В config.toml раздел [general] имеет неожиданный тип; установка остановлена.')
autostart=general.get('autostart', [])
if not isinstance(autostart, list) or not all(isinstance(x, str) for x in autostart):
    raise SystemExit('general.autostart имеет неожиданный формат; установка остановлена.')
inc=data.get('include', {}).get('optional', {}) if isinstance(data.get('include', {}), dict) else None
if inc is not None and not isinstance(inc, dict):
    raise SystemExit('include.optional имеет неожиданный формат; установка остановлена.')
if isinstance(inc, dict):
    files=inc.get('files', [])
    if not isinstance(files, list) or not all(isinstance(x, str) for x in files):
        raise SystemExit('include.optional.files имеет неожиданный формат; установка остановлена.')
PY_PREFLIGHT
fi

# Require exact minimum Noctalia generations, but use repository's complete Debian version.
candidate(){ apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'; }
NOCTALIA_CAND=$(candidate noctalia)
GREETER_CAND=$(candidate noctalia-greeter)
[[ -n "$NOCTALIA_CAND" && "$NOCTALIA_CAND" != '(none)' ]] || die 'В подключённых репозиториях нет кандидата пакета noctalia.'
[[ -n "$GREETER_CAND" && "$GREETER_CAND" != '(none)' ]] || die 'В подключённых репозиториях нет кандидата noctalia-greeter.'
dpkg --compare-versions "$NOCTALIA_CAND" ge 5.5.0 || die "Кандидат Noctalia $NOCTALIA_CAND старее требуемой версии 5.5.0."
dpkg --compare-versions "$GREETER_CAND" ge 1.7.0 || die "Кандидат Noctalia Greeter $GREETER_CAND старее требуемой версии 1.7.0."
for spec in "noctalia:$NOCTALIA_CAND" "noctalia-greeter:$GREETER_CAND"; do
  pkg=${spec%%:*}; cand=${spec#*:}
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if [[ -n "$installed" ]] && dpkg --compare-versions "$cand" lt "$installed"; then
    die "Кандидат $pkg $cand старее уже установленной версии $installed; возможный downgrade запрещён."
  fi
done

# Pin the candidates discovered above for this transaction; no backports target-release override.
APT_ARGS=(--no-install-recommends install)
for p in "${UNIQUE[@]}"; do
  case "$p" in
    noctalia) APT_ARGS+=("noctalia=$NOCTALIA_CAND") ;;
    noctalia-greeter) APT_ARGS+=("noctalia-greeter=$GREETER_CAND") ;;
    *) APT_ARGS+=("$p") ;;
  esac
done

printf '\nPACKAGE PLAN:\n'; printf '  %s\n' "${UNIQUE[@]}"
printf '\nNOCTALIA VERSION: %s\nGREETER VERSION: %s\n' "$NOCTALIA_CAND" "$GREETER_CAND"
printf '\nAPT SIMULATION:\n'
SIM_FILE=$(mktemp)
cleanup(){ rm -f "$SIM_FILE"; }
trap cleanup EXIT
if ! apt-get -s "${APT_ARGS[@]}" >"$SIM_FILE" 2>&1; then cat "$SIM_FILE"; die 'APT simulation failed. System was not changed.'; fi
cat "$SIM_FILE"
if grep -qE '^Remv ' "$SIM_FILE"; then die 'APT план содержит удаление пакетов. Установка отменена.'; fi
if grep -qE '^Inst .+ \[[^]]+\]' "$SIM_FILE"; then
  warn 'APT обновит отдельные зависимости, необходимые выбранным пакетам; это не полный upgrade системы.'
fi
if grep -qE '^Inst (gdm3|lightdm|sddm|ly|lxdm|slim|xdm|network-manager|networkmanager|ifupdown) ' "$SIM_FILE"; then
  die 'APT план затрагивает другой display manager или сетевой стек. Установка отменена.'
fi

if [[ "$MODE" == dry-run ]]; then
  printf '\nDRY-RUN COMPLETE. Ничего не установлено и не изменено.\n'
  exit 0
fi

# Existing display manager conflict: do not disable or replace it automatically.
if command -v systemctl >/dev/null 2>&1; then
  DM_TARGET=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
  if [[ -n "$DM_TARGET" && "$DM_TARGET" != *greetd.service ]]; then
    die "Уже выбран другой display manager ($DM_TARGET). Автоматическое переключение запрещено; сначала требуется отдельное решение."
  fi
  for dm in gdm3.service lightdm.service sddm.service ly.service lxdm.service slim.service xdm.service; do
    dm_state=$(systemctl is-enabled "$dm" 2>/dev/null || true)
    [[ "$dm_state" != enabled && "$dm_state" != enabled-runtime ]] || die "Другой display manager $dm уже включён. Автоматическое отключение запрещено."
  done
  if systemctl is-active --quiet display-manager.service 2>/dev/null && ! systemctl is-active --quiet greetd.service 2>/dev/null; then
    die 'Сейчас работает другой display manager. Он не будет остановлен автоматически.'
  fi
  DEFAULT_TARGET=$(systemctl get-default 2>/dev/null || true)
  case "$DEFAULT_TARGET" in
    graphical.target|multi-user.target) ;;
    *) die "Неожиданный systemd default target '$DEFAULT_TARGET'; менять его автоматически небезопасно." ;;
  esac
fi

# Refuse to proceed while another apt/dpkg transaction is running.
if command -v fuser >/dev/null 2>&1; then
  for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
    if fuser "$lock" >/dev/null 2>&1; then die "Обнаружена занятая блокировка APT/DPKG: $lock"; fi
  done
fi

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/umbriel-noctalia-$STAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [[ -d /etc/greetd ]]; then cp -a /etc/greetd "$BACKUP_DIR/"; fi
if [[ -L /etc/systemd/system/display-manager.service || -e /etc/systemd/system/display-manager.service ]]; then
  cp -a /etc/systemd/system/display-manager.service "$BACKUP_DIR/" 2>/dev/null || true
fi
if [[ -L /etc/systemd/system/default.target || -e /etc/systemd/system/default.target ]]; then
  cp -a /etc/systemd/system/default.target "$BACKUP_DIR/" 2>/dev/null || true
fi
if [[ -n "$TARGET_HOME" ]]; then
  for item in .config/noctalia .config/kitty .config/umbriel .config/autostart; do
    if [[ -e "$TARGET_HOME/$item" ]]; then
      mkdir -p "$BACKUP_DIR/home-config/$(dirname "$item")"
      cp -a "$TARGET_HOME/$item" "$BACKUP_DIR/home-config/$item" 2>/dev/null || true
    fi
  done
fi
info "Резервная копия: $BACKUP_DIR"
printf '%s\n' "$BACKUP_DIR" > /var/lib/umbriel-noctalia-last-backup 2>/dev/null || true

info 'Установка пакетов...'
if ! apt-get "${APT_ARGS[@]}"; then
  die "APT не завершил установку. Резервная копия сохранена: $BACKUP_DIR. Автоматический откат пакетов не выполняется."
fi

# Validate package-provided greeter integration; do not overwrite package-owned files.
for f in /etc/greetd/noctalia-greeter.toml /usr/bin/noctalia-greeter-session /usr/lib/systemd/system/greetd.service.d/noctalia-greeter.conf; do
  [[ -e "$f" ]] || die "После установки отсутствует ожидаемый файл $f. Greeter не включён."
done
if ! grep -qE '^command[[:space:]]*=[[:space:]]*"/usr/bin/noctalia-greeter-session"' /etc/greetd/noctalia-greeter.toml; then
  die 'Конфигурация /etc/greetd/noctalia-greeter.toml не соответствует пакетной конфигурации. greetd не включён.'
fi

# Configure Umbriel to start Noctalia through its optional include mechanism.
# Existing user config is backed up above; custom include files are never overwritten.
USER_CONFIG_DIR="$TARGET_HOME/.config/umbriel"
USER_CONFIG="$USER_CONFIG_DIR/config.toml"
INTEGRATION_CONFIG="$USER_CONFIG_DIR/noctalia-integration.toml"
install -d -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$USER_CONFIG_DIR"
if [[ ! -e "$USER_CONFIG" ]]; then
  [[ -r /usr/share/umbriel/config.toml ]] || die 'Пакет Umbriel не установил штатный /usr/share/umbriel/config.toml.'
  install -m 0644 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" /usr/share/umbriel/config.toml "$USER_CONFIG"
fi
if [[ ! -e "$INTEGRATION_CONFIG" ]]; then
  cat > "$INTEGRATION_CONFIG" <<'EOF_NOCTALIA_INTEGRATION'
# Managed integration include for Umbriel + Noctalia.
[general]
autostart = ["noctalia"]
EOF_NOCTALIA_INTEGRATION
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$INTEGRATION_CONFIG"
  chmod 0644 "$INTEGRATION_CONFIG"
else
  # Do not overwrite a pre-existing integration file; it must already be valid and launch Noctalia.
  python3 - "$INTEGRATION_CONFIG" <<'PY_EXISTING_INCLUDE'
import sys, tomllib
from pathlib import Path
p=Path(sys.argv[1])
try:
    data=tomllib.loads(p.read_text())
except Exception as exc:
    raise SystemExit(f'Существующий noctalia-integration.toml невалиден: {exc}')
a=data.get('general', {}).get('autostart', [])
if not isinstance(a, list) or not all(isinstance(x, str) for x in a):
    raise SystemExit('В noctalia-integration.toml general.autostart имеет неожиданный формат.')
if 'noctalia' not in a:
    raise SystemExit('Существующий noctalia-integration.toml не запускает Noctalia; файл не перезаписан. Исправьте его отдельно.')
PY_EXISTING_INCLUDE
fi

TARGET_USER="$TARGET_USER" USER_CONFIG="$USER_CONFIG" INTEGRATION_CONFIG="$INTEGRATION_CONFIG" python3 - <<'PY_CONFIGURE'
import json, os, re, tomllib
from pathlib import Path
cfg=Path(os.environ['USER_CONFIG'])
inc=Path(os.environ['INTEGRATION_CONFIG'])
raw=cfg.read_text()
try:
    parsed=tomllib.loads(raw)
except Exception as exc:
    raise SystemExit(f'config.toml невалиден, оставлен без изменений: {exc}')
# Preserve all optional include entries and append only our known integration file.
include=parsed.get('include', {})
if not isinstance(include, dict):
    raise SystemExit('Раздел include имеет неожиданный формат; конфигурация не изменена.')
optional=include.get('optional', {})
if not isinstance(optional, dict):
    raise SystemExit('include.optional имеет неожиданный формат; конфигурация не изменена.')
files=optional.get('files', [])
if not isinstance(files, list) or not all(isinstance(x, str) for x in files):
    raise SystemExit('include.optional.files имеет неожиданный формат; конфигурация не изменена.')
name=inc.name
if name not in files:
    files.append(name)
line='files = '+json.dumps(files, ensure_ascii=False)
pattern=r'(?ms)^\[include\.optional\][ \t]*\n(.*?)(?=^\[|\Z)'
m=re.search(pattern, raw)
if m:
    block=m.group(1)
    fm=re.search(r'(?m)^files\s*=\s*\[[^\]]*\]\s*$', block)
    if fm:
        block=block[:fm.start()]+line+'\n'+block[fm.end():]
    else:
        block=line+'\n'+block
    raw=raw[:m.start(1)]+block+raw[m.end(1):]
else:
    raw=raw.rstrip()+'\n\n[include.optional]\n'+line+'\n'
# Validate the resulting TOML before the atomic replacement.
tomllib.loads(raw)
tmp=cfg.with_name(cfg.name+'.umbriel-tmp')
tmp.write_text(raw)
os.chmod(tmp, 0o644)
os.chown(tmp, cfg.stat().st_uid, cfg.stat().st_gid)
os.replace(tmp, cfg)
PY_CONFIGURE
chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$USER_CONFIG" "$INTEGRATION_CONFIG"
chmod 0644 "$USER_CONFIG" "$INTEGRATION_CONFIG"
if ! runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" umbriel config validate; then
  die 'umbriel config validate завершился ошибкой. greetd не будет включён; резервная копия сохранена.'
fi

# Enable greetd only when no conflicting display manager is selected.
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable greetd.service || die 'Не удалось включить greetd.service.'
  if [[ $(systemctl get-default 2>/dev/null || true) == multi-user.target ]]; then
    systemctl set-default graphical.target || die 'Не удалось переключить default target на graphical.target; greetd может не запускаться при загрузке.'
  fi
  if (( ENABLE_BLUETOOTH || HAS_BT )); then
    systemctl enable bluetooth.service || warn 'Не удалось включить bluetooth.service; Bluetooth можно включить позже.'
  fi
fi

# Create standard XDG user directories without overwriting existing content.
if command -v runuser >/dev/null 2>&1 && command -v xdg-user-dirs-update >/dev/null 2>&1; then
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-user-dirs-update || warn 'Не удалось обновить XDG user directories.'
fi

# Preserve ownership and user state; no shell, keyring, SSH agent, network or power service changes.
info 'Проверка установленных пакетов:'
dpkg-query -W -f='${Package} ${Version} ${db:Status-Status}\n' umbriel noctalia noctalia-greeter greetd 2>/dev/null || true
info 'Проверка greetd:'
systemctl is-enabled greetd.service 2>/dev/null || true
printf '\nУСТАНОВКА ЗАВЕРШЕНА. Резервная копия: %s\n' "$BACKUP_DIR"
printf 'Перезагрузку скрипт не выполняет. Сначала сохраните работу и выполните обычную перезагрузку вручную.\n'
