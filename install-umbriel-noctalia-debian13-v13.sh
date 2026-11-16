#!/usr/bin/env bash
# =============================================================================
#  install-umbriel-noctalia-debian13-v13.sh
#  Umbriel + Noctalia v5.5 + Noctalia Greeter для Debian 13 (Trixie)
#  Версия 13.0.0
#
#  Основано на документации:
#    https://docs.noctalia.dev/noctalia/v5.5.0/
#    https://docs.noctalia.dev/umbriel/
#    https://docs.noctalia.dev/greeter/
#
#  Главное исправление относительно v11/v12:
#    Umbriel и libwlroots-0.20 находятся в trixie-backports и требуют
#    libdrm2 >= 2.4.129, libxkbcommon0 >= 1.8, libinput10 >= 1.29.
#    Без `-t trixie-backports` APT берёт stable-версии зависимостей
#    (приоритет 500 против 100) и получает конфликт версий.
#    Документация Umbriel → Installation предписывает:
#        sudo apt install -t trixie-backports umbriel
#    v13 применяет -t trixie-backports ко всей транзакции установки.
#
#  Режимы:
#    --report     диагностика, ничего не меняет (по умолчанию)
#    --dry-run    симуляция APT, ничего не меняет
#    --install    полная установка
# =============================================================================
set -Eeuo pipefail
IFS=$' \n\t'
umask 022

SCRIPT_VERSION='13.0.0'
PROGRAM=${0##*/}

# --- параметры ---------------------------------------------------------------
MODE=''
VERBOSE=0
TARGET_USER=''
ENABLE_BLUETOOTH=0
ENABLE_VM_INTEGRATION=0
ENABLE_NM=0
WITH_GREETER=1
REPLACE_DM=0
NO_REPO_CHANGES=0
LOCALE_OVERRIDE=''
LOCALE_CHANGES=1
DISABLE_KEYRING=1
WITH_RECOMMENDS=1
ALLOW_REMOVALS=0
SKIP_OPTIONAL=0
SKIP_FIRMWARE=0
STRICT_VERSIONS=0
TARGET_RELEASE='trixie-backports'
MIN_NOCTALIA='5.5.0'
MIN_GREETER='1.7.0'

NOCTALIA_KEYRING_URL='https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb'
NOCTALIA_SOURCES_URL='https://pkg.noctalia.dev/deb/noctalia-trixie.sources'
NOCTALIA_SOURCES_FILE='/etc/apt/sources.list.d/noctalia-trixie.sources'
BACKPORTS_FILE='/etc/apt/sources.list.d/debian-trixie-backports.sources'
LOG_FILE='/var/log/umbriel-noctalia-install.log'

BACKUP_DIR=''
TMP_DIR=''
SIM_FILE=''

APT_OPTS=(-y -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_SUSPEND=1
# Все парсинги apt/dpkg — только в C-локали.
export LC_ALL=C
unset LANGUAGE || true

# --- вывод -------------------------------------------------------------------
info(){  printf '[INFO] %s\n'  "$*"; }
warn(){  printf '[WARN] %s\n'  "$*" >&2; }
err(){   printf '[ERROR] %s\n' "$*" >&2; }
die(){   err "$*"; exit 1; }
debug(){ if (( VERBOSE )); then printf '[DEBUG] %s\n' "$*" >&2; fi; return 0; }
section(){ printf '\n============================================================\n%s\n============================================================\n' "$*"; }

cleanup(){
  local rc=$?
  [[ -z $SIM_FILE || ! -f $SIM_FILE ]] || rm -f -- "$SIM_FILE"
  [[ -z $TMP_DIR  || ! -d $TMP_DIR  ]] || rm -rf -- "$TMP_DIR"
  return "$rc"
}
trap cleanup EXIT

usage(){ cat <<EOF
$PROGRAM $SCRIPT_VERSION — Debian 13 Trixie (amd64/arm64)

Использование:
  $PROGRAM --report
  sudo $PROGRAM --setup-repos
  $PROGRAM --dry-run [параметры]
  sudo $PROGRAM --install [параметры]

Режимы:
  --report                 Диагностика без изменений (по умолчанию).
  --setup-repos            Подключить ключ/репозиторий Noctalia и trixie-backports.
  --dry-run                Симуляция APT. Ничего не меняет.
  --install                Полная установка.

Параметры:
  --user USER              Целевой пользователь (по умолчанию \$SUDO_USER).
  --enable-vm-integration  Гостевые агенты для обнаруженного гипервизора.
  --enable-bluetooth       BlueZ + Bluetooth-модуль PipeWire.
  --enable-network-manager NetworkManager (нужен виджету сети Noctalia).
  --no-greeter             Не устанавливать/не включать Noctalia Greeter.
  --replace-display-manager Разрешить отключение текущего DM (служба не стопается).
  --no-recommends          Не ставить Recommends (по умолчанию ставятся).
  --allow-removals         Разрешить удаления вне белого списка.
  --no-repo-changes        Запретить изменение репозиториев.
  --no-optional            Без необязательных приложений.
  --no-firmware            Без firmware/guest-пакетов по железу.
  --no-locale-changes      Не трогать системную локаль.
  --locale LOCALE          Задать локаль, например ru_RU.UTF-8.
  --disable-gnome-keyring  Отключить autostart GNOME Keyring (по умолчанию включено).
  --strict-versions        Сделать пороги версий жёсткими.
  --target-release NAME    Target-release APT (по умолчанию trixie-backports).
  --keyring-url URL        Переопределить URL ключа Noctalia.
  --sources-url URL        Переопределить URL .sources Noctalia.
  --verbose                Подробный вывод.
  -h, --help               Справка.

Быстрый путь для KVM:
  sudo ./$PROGRAM --install --enable-vm-integration
EOF
}

take_value(){ [[ -n ${2:-} && ${2} != -* ]] || die "После $1 требуется значение (получено: '${2:-}')."; }

while (($#)); do
  case "$1" in
    --report)      [[ -z $MODE ]] || die 'Укажите только один режим.'; MODE=report ;;
    --setup-repos) [[ -z $MODE ]] || die 'Укажите только один режим.'; MODE=setup-repos ;;
    --dry-run)     [[ -z $MODE ]] || die 'Укажите только один режим.'; MODE=dry-run ;;
    --install)     [[ -z $MODE ]] || die 'Укажите только один режим.'; MODE=install ;;
    --enable-vm-integration)  ENABLE_VM_INTEGRATION=1 ;;
    --enable-bluetooth)       ENABLE_BLUETOOTH=1 ;;
    --enable-network-manager) ENABLE_NM=1 ;;
    --no-greeter)             WITH_GREETER=0 ;;
    --replace-display-manager) REPLACE_DM=1 ;;
    --no-recommends)          WITH_RECOMMENDS=0 ;;
    --allow-removals)         ALLOW_REMOVALS=1 ;;
    --no-repo-changes)        NO_REPO_CHANGES=1 ;;
    --no-optional)            SKIP_OPTIONAL=1 ;;
    --no-firmware)            SKIP_FIRMWARE=1 ;;
    --no-locale-changes)      LOCALE_CHANGES=0 ;;
    --disable-gnome-keyring)  DISABLE_KEYRING=1 ;;
    --strict-versions)        STRICT_VERSIONS=1 ;;
    --verbose)                VERBOSE=1 ;;
    --user)           take_value "$1" "${2:-}"; TARGET_USER=$2; shift ;;
    --locale)         take_value "$1" "${2:-}"; LOCALE_OVERRIDE=$2; shift ;;
    --target-release) take_value "$1" "${2:-}"; TARGET_RELEASE=$2; shift ;;
    --keyring-url)    take_value "$1" "${2:-}"; NOCTALIA_KEYRING_URL=$2; shift ;;
    --sources-url)    take_value "$1" "${2:-}"; NOCTALIA_SOURCES_URL=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
  shift
done
MODE=${MODE:-report}

# --- проверки окружения ------------------------------------------------------
for c in awk bash dpkg dpkg-query grep sed uname getent id install cp; do
  command -v "$c" >/dev/null 2>&1 || die "Не найдена обязательная команда: $c"
done
[[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] \
  || die "Поддерживается только Debian 13 Trixie; обнаружено: ${PRETTY_NAME:-unknown}."
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64|arm64) ;; *) die "Архитектура $ARCH не поддерживается." ;; esac

if [[ $MODE == install || $MODE == setup-repos ]]; then
  [[ $EUID -eq 0 ]] || die "Для --$MODE запустите скрипт через sudo."
  command -v apt-get >/dev/null 2>&1 || die 'Не найден apt-get.'
fi
command -v apt-cache >/dev/null 2>&1 || die 'Не найден apt-cache.'

# --- пользователь ------------------------------------------------------------
if [[ -z $TARGET_USER ]]; then
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then TARGET_USER=$SUDO_USER
  elif [[ $EUID -ne 0 ]]; then TARGET_USER=$(id -un)
  else TARGET_USER=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1; exit}')
  fi
fi
TARGET_HOME=''; TARGET_GROUP=''; TARGET_UID=''
if [[ -n $TARGET_USER ]]; then
  getent passwd "$TARGET_USER" >/dev/null 2>&1 || die "Пользователь '$TARGET_USER' не найден."
  TARGET_HOME=$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')
  TARGET_GROUP=$(id -gn "$TARGET_USER")
  TARGET_UID=$(id -u "$TARGET_USER")
  [[ -n $TARGET_HOME && -d $TARGET_HOME && $TARGET_HOME != / ]] \
    || die "Некорректный HOME пользователя '$TARGET_USER': '$TARGET_HOME'"
fi

# --- детект железа -----------------------------------------------------------
VIRT=none; CONTAINER=none; CHASSIS=unknown
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt --vm 2>/dev/null || true); VIRT=${VIRT:-none}
  CONTAINER=$(systemd-detect-virt --container 2>/dev/null || true); CONTAINER=${CONTAINER:-none}
fi
if command -v hostnamectl >/dev/null 2>&1; then CHASSIS=$(hostnamectl chassis 2>/dev/null || true); fi
if [[ -z $CHASSIS || $CHASSIS == unknown ]] && [[ -r /sys/class/dmi/id/chassis_type ]]; then
  case "$(< /sys/class/dmi/id/chassis_type)" in
    8|9|10|14) CHASSIS=laptop ;;
    3|4|5|6|7|15|16) CHASSIS=desktop ;;
  esac
fi
HAS_BATTERY=0
for p in /sys/class/power_supply/*; do
  [[ -r "$p/type" ]] || continue
  if [[ $(<"$p/type") == Battery ]]; then HAS_BATTERY=1; fi
done
if [[ $VIRT != none || $CONTAINER != none ]]; then MACHINE_CLASS=virtual-machine
elif [[ $CHASSIS == laptop ]] || (( HAS_BATTERY )); then MACHINE_CLASS=laptop
elif [[ $CHASSIS == desktop ]]; then MACHINE_CLASS=desktop
else MACHINE_CLASS=physical-unknown; fi

PCI_LIST=''
if command -v lspci >/dev/null 2>&1; then PCI_LIST=$(lspci -nn 2>/dev/null || true); fi
GPU_INFO=$(grep -Ei 'VGA compatible controller|3D controller|Display controller' <<<"$PCI_LIST" || true)
NETWORK_INFO=$(grep -Ei 'Ethernet controller|Network controller|Wireless' <<<"$PCI_LIST" || true)
AUDIO_INFO=$(grep -Ei 'Audio device|Multimedia audio controller' <<<"$PCI_LIST" || true)
GPU_INTEL=0; GPU_AMD=0; GPU_NVIDIA=0
grep -qi intel <<<"$GPU_INFO" && GPU_INTEL=1 || true
grep -qiE 'AMD|ATI' <<<"$GPU_INFO" && GPU_AMD=1 || true
grep -qi nvidia <<<"$GPU_INFO" && GPU_NVIDIA=1 || true

HAS_WIFI=0
for p in /sys/class/net/*; do
  [[ -e "$p/wireless" || -e "$p/phy80211" ]] && HAS_WIFI=1
done
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

# --- APT-хелперы (C-локаль, защита от pipefail) ------------------------------
apt_candidate(){ LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ {print $2; exit}' || true; }
apt_known(){ LC_ALL=C apt-cache show "$1" >/dev/null 2>&1 || true; }
apt_avail(){ local c; c=$(apt_candidate "$1"); if [[ -n $c && $c != '(none)' ]]; then return 0; fi; apt_known "$1"; }
have_release(){ LC_ALL=C apt-cache policy 2>/dev/null | grep -qE "(^|[[:space:]])${1}([[:space:]]|$)" || true; }
pkg_installed(){ dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed || true; }
norm_version(){ local v=${1#*:}; v=${v%%~*}; v=${v%%+*}; printf '%s' "$v"; }
json_str(){ python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

# --- отчёт -------------------------------------------------------------------
section "UMBRIEL + NOCTALIA INSTALLER $SCRIPT_VERSION"
printf 'MODE: %s\nOS: %s\nARCH: %s\nKERNEL: %s\n' "$MODE" "${PRETTY_NAME:-Debian}" "$ARCH" "$(uname -r)"
printf 'MACHINE: %s\nVIRTUALIZATION: %s\nCONTAINER: %s\nCHASSIS: %s\n' "$MACHINE_CLASS" "$VIRT" "$CONTAINER" "$CHASSIS"
printf 'BATTERY: %s\nWI-FI: %s\nBLUETOOTH: %s\n' \
  "$( ((HAS_BATTERY)) && echo PRESENT || echo NOT-DETECTED)" \
  "$( ((HAS_WIFI)) && echo PRESENT || echo NOT-DETECTED)" \
  "$( ((HAS_BT)) && echo PRESENT || echo NOT-DETECTED)"
printf 'NETWORK STACK: %s\nCONNECTED DRM OUTPUTS: %s\n' "$NETWORK_STACK" "$CONNECTED_DRM"
printf '\nGPU:\n%s\nNETWORK:\n%s\nAUDIO:\n%s\n' \
  "${GPU_INFO:-  not detected}" "${NETWORK_INFO:-  not detected}" "${AUDIO_INFO:-  not detected}"
if [[ -n $TARGET_USER ]]; then printf '\nTARGET USER: %s\nHOME: %s\n' "$TARGET_USER" "$TARGET_HOME"; fi

if command -v systemctl >/dev/null 2>&1; then
  printf '\nDISPLAY / CORE SERVICES:\n'
  for u in greetd.service display-manager.service NetworkManager.service networking.service bluetooth.service; do
    a=$(systemctl is-active "$u" 2>/dev/null || true)
    e=$(systemctl is-enabled "$u" 2>/dev/null || true)
    printf '  %-30s active=%-10s enabled=%s\n' "$u" "${a:-unknown}" "${e:-unknown}"
  done
fi

printf '\nAPT CANDIDATES:\n'
for p in umbriel noctalia noctalia-greeter greetd xdg-desktop-portal-umbriel; do
  printf '  %-30s %s\n' "$p" "$(apt_candidate "$p")"
done
printf '  %-30s %s\n' 'trixie-backports' "$(have_release trixie-backports && echo present || echo absent)"

if [[ $MODE == report ]]; then
  printf '\nREPORT COMPLETE; изменений не внесено.\n'
  printf 'Дальше: sudo %s --setup-repos, затем --dry-run, затем --install.\n' "$PROGRAM"
  exit 0
fi

[[ -n $TARGET_USER ]] || die 'Не удалось определить пользователя. Укажите --user USER.'
[[ $(id -u "$TARGET_USER") -ne 0 ]] || die 'Целевой пользователь не должен быть root.'
[[ $CONTAINER == none ]] || die "Обнаружен контейнер '$CONTAINER': установка графического стека не поддерживается."

# --- журнал и рабочий каталог ------------------------------------------------
if [[ $MODE == install || $MODE == setup-repos ]]; then
  mkdir -p /var/log
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Версия $SCRIPT_VERSION; журнал: $LOG_FILE"
fi
TMP_DIR=$(mktemp -d /tmp/umbriel-noctalia.XXXXXX)

# --- backup ------------------------------------------------------------------
init_backup(){
  [[ -n $BACKUP_DIR ]] && return 0
  BACKUP_DIR="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "$BACKUP_DIR" || die "Не удалось создать $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  printf '%s\n' "$BACKUP_DIR" > /var/lib/umbriel-noctalia-last-backup 2>/dev/null || true
  info "Резервные копии: $BACKUP_DIR"
  return 0
}
backup_path(){
  local src=$1 dst="$BACKUP_DIR/$2"
  [[ -e $src || -L $src ]] || return 0
  mkdir -p -- "$(dirname -- "$dst")" || die "Не удалось создать каталог backup для $src"
  cp -a -- "$src" "$dst" || die "Backup $src не удался; установка остановлена (данные не изменены)."
  debug "backup: $src → $dst"
  return 0
}

# --- базовые инструменты -----------------------------------------------------
ensure_tools(){
  local need=() p
  for p in ca-certificates curl wget gnupg python3 pciutils; do
    pkg_installed "$p" || need+=("$p")
  done
  if ((${#need[@]})); then
    info "Установка базовых инструментов: ${need[*]}"
    apt-get "${APT_OPTS[@]}" install "${need[@]}" || die 'Не удалось установить базовые инструменты.'
  fi
  return 0
}

# --- репозитории -------------------------------------------------------------
has_backports_elsewhere(){
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f $f ]] || continue
    if grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]trixie-backports([[:space:]]|$)' "$f"; then return 0; fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f $f ]] || continue
    [[ $f == "$BACKPORTS_FILE" ]] && continue
    if grep -Eq '^Suites:.*(^|[[:space:]])trixie-backports([[:space:]]|$)' "$f" \
       && grep -Eq '^URIs:.*https?://(deb\.)?debian\.org/' "$f"; then return 0; fi
  done
  return 1
}

setup_repos(){
  init_backup
  section 'ПОДКЛЮЧЕНИЕ РЕПОЗИТОРИЕВ'
  backup_path /etc/apt/sources.list 'apt/sources.list'
  backup_path /etc/apt/sources.list.d 'apt/sources.list.d'

  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f $f ]] || continue
    if grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' "$f"; then
      sed -i -E 's/^([[:space:]]*deb[[:space:]]+)cdrom:/\1# cdrom:/' "$f" \
        || die "Не удалось отключить cdrom-запись в $f"
      info "Отключена cdrom-запись: $f"
    fi
  done

  apt-get "${APT_OPTS[@]}" update || warn 'Первичный apt-get update завершился ошибкой; пробую продолжить.'
  ensure_tools

  # contrib/non-free/non-free-firmware только к официальным stanzas Debian.
  python3 - <<'PY_COMPONENTS'
from pathlib import Path
import re
files=[Path('/etc/apt/sources.list'),
       *Path('/etc/apt/sources.list.d').glob('*.sources'),
       *Path('/etc/apt/sources.list.d').glob('*.list')]
extra=('contrib','non-free','non-free-firmware')
for p in files:
    if not p.is_file() or 'noctalia' in p.name or 'backports' in p.name: continue
    text=p.read_text(errors='replace'); old=text
    if p.suffix=='.sources':
        out=[]
        for b in re.split(r'(?=^Types:)', text, flags=re.M):
            if re.search(r'^URIs:\s*https?://(?:deb|security)\.debian\.org/', b, re.M) and \
               re.search(r'^Suites:.*\b(?:trixie|stable|trixie-updates|trixie-security)\b', b, re.M):
                m=re.search(r'^Components:\s*(.*)$', b, re.M)
                if m:
                    comps=m.group(1).split()
                    for c in extra:
                        if c not in comps: comps.append(c)
                    b=b[:m.start(1)]+' '.join(comps)+b[m.end(1):]
            out.append(b)
        text=''.join(out)
    else:
        lines=[]
        for line in text.splitlines(True):
            if re.match(r'^\s*deb\s+', line) and re.search(r'https?://(?:deb|security)\.debian\.org/', line):
                s=line.rstrip('\n')
                for c in extra:
                    if not re.search(rf'\s{re.escape(c)}(?:\s|$)', s): s+=' '+c
                line=s+'\n'
            lines.append(line)
        text=''.join(lines)
    if text!=old:
        p.write_text(text)
        print(f'[INFO] дополнены компоненты Debian: {p}')
PY_COMPONENTS

  if has_backports_elsewhere; then
    if [[ -f $BACKPORTS_FILE ]] && grep -Eq '^Suites:.*trixie-backports' "$BACKPORTS_FILE"; then
      backup_path "$BACKPORTS_FILE" 'apt/duplicate-backports.sources'
      rm -f -- "$BACKPORTS_FILE"
      info 'Удалён дублирующий файл backports (копия сохранена).'
    else
      info 'trixie-backports уже настроен elsewhere.'
    fi
  elif [[ ! -f $BACKPORTS_FILE ]]; then
    cat > "$BACKPORTS_FILE" <<'EOF_BACKPORTS'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_BACKPORTS
    info 'Добавлен Debian trixie-backports (нужен для зависимостей Umbriel).'
  fi

  info 'Установка ключа репозитория Noctalia...'
  wget --https-only --timeout=60 --tries=3 -q "$NOCTALIA_KEYRING_URL" -O "$TMP_DIR/keyring.deb" \
    || die "Не удалось скачать ключ Noctalia: $NOCTALIA_KEYRING_URL (см. --keyring-url)."
  dpkg-deb --info "$TMP_DIR/keyring.deb" >/dev/null 2>&1 \
    || die 'Скачанный файл ключа не является .deb (прокси вернул HTML?).'
  dpkg -i "$TMP_DIR/keyring.deb" || die 'Не удалось установить пакет ключа Noctalia.'

  info 'Установка описания репозитория Noctalia...'
  wget --https-only --timeout=60 --tries=3 -q "$NOCTALIA_SOURCES_URL" -O "$TMP_DIR/noctalia.sources" \
    || die "Не удалось скачать .sources: $NOCTALIA_SOURCES_URL (см. --sources-url)."
  grep -q '^Types:' "$TMP_DIR/noctalia.sources" && grep -q '^URIs:' "$TMP_DIR/noctalia.sources" \
    || die 'Скачанный .sources не похож на deb822-описание репозитория.'
  if grep -q '^Architectures:' "$TMP_DIR/noctalia.sources"; then
    grep -qE "^Architectures:.*(^|[[:space:]])${ARCH}([[:space:]]|$)" "$TMP_DIR/noctalia.sources" \
      || die "Репозиторий Noctalia не публикует пакеты для $ARCH."
  fi
  backup_path "$NOCTALIA_SOURCES_FILE" 'apt/noctalia-trixie.sources.pre'
  install -m 0644 "$TMP_DIR/noctalia.sources" "$NOCTALIA_SOURCES_FILE"

  apt-get "${APT_OPTS[@]}" update || die 'apt-get update после подключения Noctalia не удался.'
  info 'Репозитории подключены.'
  return 0
}

repos_needed(){
  local p c
  for p in umbriel noctalia; do
    c=$(apt_candidate "$p")
    [[ -z $c || $c == '(none)' ]] && return 0
  done
  if (( WITH_GREETER )); then
    c=$(apt_candidate noctalia-greeter)
    [[ -z $c || $c == '(none)' ]] && return 0
  fi
  return 1
}

apt_diagnostics(){
  warn '--- Диагностика APT ---'
  LC_ALL=C apt-cache policy umbriel noctalia noctalia-greeter greetd \
    xdg-desktop-portal-umbriel libdrm2 libinput10 libxkbcommon0 libwlroots-0.20 2>/dev/null || true
  LC_ALL=C apt-cache policy libpipewire-0.3-0t64 libspa-0.2-modules pipewire wireplumber \
    mesa-libgallium libgl1-mesa-dri 2>/dev/null || true
  warn 'Поиск пакетов проекта в индексах:'
  LC_ALL=C apt-cache search --names-only 'noctalia|umbriel' 2>/dev/null || true
  local held; held=$(apt-mark showhold 2>/dev/null || true)
  if [[ -n $held ]]; then warn 'Удерживаемые пакеты (apt-mark hold):'; printf '%s\n' "$held" >&2; fi
  warn 'Источники Noctalia/backports:'
  grep -RniE 'noctalia|trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null >&2 || true
  return 0
}

# --- режим setup-repos -------------------------------------------------------
if [[ $MODE == setup-repos ]]; then
  setup_repos
  section 'РЕПОЗИТОРИИ ГОТОВЫ'
  for p in umbriel noctalia noctalia-greeter; do
    printf '  %-24s %s\n' "$p" "$(apt_candidate "$p")"
  done
  printf '\nДальше:\n  %s --dry-run --enable-vm-integration\n  sudo %s --install --enable-vm-integration\n' "$PROGRAM" "$PROGRAM"
  exit 0
fi

# --- режим install: инструменты и репозитории --------------------------------
if [[ $MODE == install ]]; then
  ensure_tools
  if repos_needed; then
    if (( NO_REPO_CHANGES )); then
      apt_diagnostics
      die "Нужных пакетов нет в APT, а --no-repo-changes запрещает правку источников.
Выполните отдельно: sudo $PROGRAM --setup-repos"
    fi
    setup_repos
  else
    info 'Пакеты проекта уже видны в APT; источники не изменяются.'
    apt-get "${APT_OPTS[@]}" update || warn 'apt-get update завершился ошибкой; использую текущие индексы.'
  fi
fi

if ! command -v python3 >/dev/null 2>&1 && [[ $MODE == install ]]; then
  die 'python3 недоступен.'
fi

# --- preflight TOML ----------------------------------------------------------
USER_CONFIG_DIR="$TARGET_HOME/.config/umbriel"
USER_CONFIG="$USER_CONFIG_DIR/config.toml"
INTEGRATION_CONFIG="$USER_CONFIG_DIR/noctalia-integration.toml"
if command -v python3 >/dev/null 2>&1 && [[ -f $USER_CONFIG ]]; then
  python3 - "$USER_CONFIG" <<'PY' || die "Существующий $USER_CONFIG невалиден; исправьте вручную."
import sys, tomllib
from pathlib import Path
tomllib.loads(Path(sys.argv[1]).read_text())
PY
  debug 'preflight TOML пройден'
fi

# --- набор пакетов -----------------------------------------------------------
declare -A SEEN=()
PACKAGES=(); MISSING_PKGS=()
add_pkg(){ local p; for p in "$@"; do
    [[ -n $p ]] || continue
    [[ ${SEEN[$p]+x} ]] && continue
    SEEN[$p]=1; PACKAGES+=("$p")
  done; return 0; }
add_available(){ local p; for p in "$@"; do
    [[ ${SEEN[$p]+x} ]] && continue
    if apt_avail "$p"; then add_pkg "$p"; else MISSING_PKGS+=