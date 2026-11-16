#!/usr/bin/env bash
# =============================================================================
#  install-umbriel-noctalia-debian13-v12.sh
#  Umbriel + Noctalia + Noctalia Greeter для Debian 13 (Trixie), amd64/arm64
#  Версия 12.0.0
#
#  Что исправлено относительно v11:
#   • возвращено подключение репозиториев (ключ Noctalia + .sources + backports)
#   • возвращён target-release trixie-backports, убраны жёсткие пины версий
#   • возвращён полный набор Qt/QML/Mesa/accountsservice/ports/firmware
#   • Recommends включены по умолчанию (как в работавшей v10)
#   • все проверки APT выполняются в LC_ALL=C (баг русской локали)
#   • пороги версий — предупреждение, а не остановка (учтён суффикс ~git)
#   • удаления пакетов — белый список (pulseaudio → pipewire-pulse), не запрет
#   • greetd настраивается через реальный effective-config, а не через
#     фиксированные пути и кавычки; возвращён --setup-system
#   • надёжный TOML-редактор вместо хрупкого regex (комментарии, multiline,
#     dotted-ключи, симлинки, атомарная запись, semantic-проверка)
#   • python3 ставится ДО проверки TOML; ошибки backup не проглатываются
#   • возвращены: BlueZ drop-in для VM, XKB/кейбинды, kitty, локаль, лог
#
#  Безопасность сохранена из v11:
#   • режим по умолчанию --report (ничего не меняет)
#   • --dry-run не меняет вообще ничего (даже индексы APT)
#   • чужой display manager не отключается без --replace-display-manager
#   • нет autoremove / full-upgrade / переустановки сетевого стека
#   • backup перед каждым изменением, при ошибке backup — остановка
# =============================================================================
set -Eeuo pipefail
IFS=$' \n\t'
umask 022

SCRIPT_VERSION='12.0.0'
PROGRAM=${0##*/}

# --- параметры по умолчанию --------------------------------------------------
MODE=''
VERBOSE=0
TARGET_USER=''
ENABLE_BLUETOOTH=0
ENABLE_VM_INTEGRATION=0
ENABLE_NM=0
WITH_RECOMMENDS=1
ALLOW_REMOVALS=0
REPLACE_DM=0
WITH_GREETER=1
NO_REPO_CHANGES=0
SKIP_OPTIONAL=0
SKIP_FIRMWARE=0
LOCALE_CHANGES=1
LOCALE_OVERRIDE=''
DISABLE_KEYRING=0
STRICT_VERSIONS=0
FORCE_GREETER=0
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
TOML_TOOL=''

APT_OPTS=(-y -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_SUSPEND=1
# Ключевое исправление локали: весь вывод apt/dpkg парсится в C-локали.
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
  if [[ -n $SIM_FILE && -f $SIM_FILE ]]; then rm -f -- "$SIM_FILE"; fi
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi
  return "$rc"
}
trap cleanup EXIT
trap 'err "Неожиданный сбой: строка $LINENO, команда: $BASH_COMMAND"' ERR

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
  --dry-run                Симуляция APT. Не меняет ничего, root не нужен.
  --install                Полная установка. Репозитории подключаются
                           автоматически, если нужных пакетов нет в APT.

Параметры:
  --user USER              Целевой пользователь (по умолчанию \$SUDO_USER).
  --enable-vm-integration  Гостевые агенты для обнаруженного гипервизора.
  --enable-bluetooth       BlueZ + Bluetooth-модуль PipeWire.
  --enable-network-manager NetworkManager (нужен виджету сети Noctalia).
                           networking.service НЕ отключается.
  --no-greeter             Не устанавливать/не включать Noctalia Greeter.
  --replace-display-manager Явно разрешить отключение текущего DM
                           (пакеты и конфиги не удаляются, служба не стопается).
  --no-recommends          Не ставить Recommends (по умолчанию ставятся).
  --allow-removals         Разрешить удаления пакетов вне белого списка.
  --no-repo-changes        Запретить изменение репозиториев.
  --no-optional            Без необязательных приложений.
  --no-firmware            Без firmware/guest-пакетов по железу.
  --no-locale-changes      Не трогать системную локаль.
  --locale LOCALE          Задать локаль, например ru_RU.UTF-8.
  --disable-gnome-keyring  Отключить autostart GNOME Keyring (как в v10).
  --strict-versions        Сделать пороги версий жёсткими.
  --force-greeter          Включить greetd даже если config validate упал.
  --target-release NAME    Target-release APT (по умолчанию trixie-backports).
  --keyring-url URL        Переопределить URL ключа Noctalia.
  --sources-url URL        Переопределить URL .sources Noctalia.
  --verbose                Подробный вывод.
  -h, --help               Справка.

Быстрый путь для вашей KVM-машины:
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
    --force-greeter)          FORCE_GREETER=1 ;;
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
if grep -qi intel <<<"$GPU_INFO"; then GPU_INTEL=1; fi
if grep -qiE 'AMD|ATI' <<<"$GPU_INFO"; then GPU_AMD=1; fi
if grep -qi nvidia <<<"$GPU_INFO"; then GPU_NVIDIA=1; fi

HAS_WIFI=0
for p in /sys/class/net/*; do
  if [[ -e "$p/wireless" || -e "$p/phy80211" ]]; then HAS_WIFI=1; fi
done
HAS_BT=0
for p in /sys/class/bluetooth/*; do
  if [[ -e "$p" ]]; then HAS_BT=1; fi
done
CONNECTED_DRM=0
for p in /sys/class/drm/*/status; do
  [[ -r "$p" ]] || continue
  if [[ $(<"$p") == connected ]]; then CONNECTED_DRM=$((CONNECTED_DRM+1)); fi
done
NETWORK_STACK=unknown
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then NETWORK_STACK=NetworkManager-active
  elif systemctl is-active --quiet networking.service 2>/dev/null; then NETWORK_STACK=networking-service-active
  elif [[ -f /etc/network/interfaces ]]; then NETWORK_STACK=ifupdown-config-present
  fi
fi

# --- APT-хелперы (все в C-локали) -------------------------------------------
apt_candidate(){ LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ {print $2; exit}'; }
apt_known(){ LC_ALL=C apt-cache show "$1" >/dev/null 2>&1; }
apt_avail(){ local c; c=$(apt_candidate "$1"); if [[ -n $c && $c != '(none)' ]]; then return 0; fi; apt_known "$1"; }
have_release(){ LC_ALL=C apt-cache policy 2>/dev/null | grep -qE "(^|[[:space:]])${1}([[:space:]]|$)"; }
pkg_installed(){ dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }
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
  printf '  %-30s %s\n' "$p" "$(apt_candidate "$p" || echo '?')"
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
TOML_TOOL="$TMP_DIR/toml_tool.py"

# =============================================================================
#  Надёжный TOML-редактор (stdlib). Сохраняет комментарии/форматирование,
#  понимает dotted-ключи, multiline-массивы, inline-таблицы; пишет атомарно,
#  проверяет результат и по синтаксису, и по значению.
# =============================================================================
cat > "$TOML_TOOL" <<'PY_TOML_TOOL'
#!/usr/bin/env python3
"""toml_tool.py validate FILE | get FILE key.path | set FILE key.path JSON"""
import json, os, re, sys, tempfile, tomllib
from pathlib import Path

def fail(msg):
    print(f'[toml] {msg}', file=sys.stderr); sys.exit(1)

def code_part(line):
    """Строка без комментария '#' вне кавычек."""
    out=[]; quote=None; i=0
    while i < len(line):
        ch=line[i]
        if quote:
            out.append(ch)
            if ch=='\\' and quote=='"':
                if i+1 < len(line):
                    out.append(line[i+1]); i+=2; continue
            elif ch==quote:
                quote=None
        elif ch in '"\'':
            quote=ch; out.append(ch)
        elif ch=='#':
            break
        else:
            out.append(ch)
        i+=1
    return ''.join(out)

STRINGS=re.compile(r'"(?:[^"\\]|\\.)*"|\'[^\'\\]*\'')

def depth_delta(code):
    code=STRINGS.sub('""', code)
    return code.count('[')-code.count(']')+code.count('{')-code.count('}')

def split_key(key):
    parts=[]; cur=''; quote=None
    for ch in key:
        if quote:
            if ch==quote: quote=None
            else: cur+=ch
        elif ch in '"\'': quote=ch
        elif ch=='.': parts.append(cur.strip()); cur=''
        else: cur+=ch
    parts.append(cur.strip())
    return parts

HEADER=re.compile(r'^\s*\[([^\[\]]+)\]\s*$')
ASSIGN=re.compile(r'^([ \t]*)([A-Za-z0-9_\-."\' ]+?)\s*=')

def scan(lines):
    tables=[]; records=[]; table=''; depth=0; pending=None
    for idx, line in enumerate(lines):
        code=code_part(line)
        if depth==0 and pending is None:
            h=HEADER.match(code)
            if h:
                table='.'.join(split_key(h.group(1)))
                tables.append({'name':table,'index':idx})
                continue
            m=ASSIGN.match(code)
            if m:
                key='.'.join(split_key(m.group(2)))
                path=f'{table}.{key}' if table else key
                pending={'path':path,'lhs':m.group(2).strip(),'indent':m.group(1),'start':idx}
        depth+=depth_delta(code)
        if pending is not None and depth<=0:
            pending['end']=idx; records.append(pending); pending=None; depth=0
    return tables, records

def load(path):
    try:
        return tomllib.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {}
    except Exception as exc:
        fail(f'{path}: некорректный TOML: {exc}')

def dig(data, parts):
    cur=data
    for k in parts:
        if not isinstance(cur, dict) or k not in cur: return None, False
        cur=cur[k]
    return cur, True

def atomic_write(target, text, template=None):
    st=None
    for p in (target, template):
        if p is not None and p.exists():
            st=p.stat(); break
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=target.name+'.', suffix='.tmp', dir=str(target.parent))
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as fh:
            fh.write(text); fh.flush(); os.fsync(fh.fileno())
        if st is not None:
            os.chmod(tmp, st.st_mode & 0o7777)
            try: os.chown(tmp, st.st_uid, st.st_gid)
            except PermissionError: pass
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp): os.unlink(tmp)
        raise

def do_get(file_arg, keypath):
    p=Path(file_arg)
    if not p.exists(): sys.exit(3)
    val, ok = dig(load(p), split_key(keypath))
    if not ok: sys.exit(3)
    print(json.dumps(val, ensure_ascii=False))

def do_set(file_arg, keypath, value_json):
    orig=Path(file_arg)
    target=orig.resolve() if orig.exists() else orig   # не ломаем симлинки dotfiles
    try: value=json.loads(value_json)
    except Exception as exc: fail(f'значение не JSON: {exc}')
    if not isinstance(value,(str,list)): fail('поддерживаются строки и массивы строк')
    if isinstance(value,list) and not all(isinstance(x,str) for x in value):
        fail('массив должен содержать только строки')
    parts=split_key(keypath)
    if len(parts)<2: fail('ключ должен иметь вид section.key')
    raw=target.read_text(encoding='utf-8') if target.exists() else ''
    lines=raw.splitlines(keepends=True)
    tables, records = scan(lines)
    rendered=json.dumps(value, ensure_ascii=False)
    full='.'.join(parts)
    rec=next((r for r in records if r['path']==full), None)
    if rec is not None:
        lines[rec['start']:rec['end']+1]=[f"{rec['indent']}{rec['lhs']} = {rendered}\n"]
    else:
        placed=False
        for n in range(len(parts)-1, 0, -1):
            ancestor='.'.join(parts[:n])
            t=next((t for t in tables if t['name']==ancestor), None)
            if t is not None:
                lines.insert(t['index']+1, f"{'.'.join(parts[n:])} = {rendered}\n")
                placed=True; break
        if not placed:
            if lines and not lines[-1].endswith('\n'): lines[-1]+='\n'
            if lines: lines.append('\n')
            lines.append('['+'.'.join(parts[:-1])+']\n')
            lines.append(f'{parts[-1]} = {rendered}\n')
    new=''.join(lines)
    try: data=tomllib.loads(new)
    except Exception as exc: fail(f'результат невалиден, файл не изменён: {exc}')
    got, ok = dig(data, parts)
    if not ok or got != value: fail('проверка значения не пройдена; файл не изменён')
    atomic_write(target, new, template=orig)

def main():
    if len(sys.argv)<3: fail('недостаточно аргументов')
    cmd=sys.argv[1]
    if cmd=='validate' and len(sys.argv)==3: load(Path(sys.argv[2])); return
    if cmd=='get' and len(sys.argv)==4: do_get(sys.argv[2], sys.argv[3]); return
    if cmd=='set' and len(sys.argv)==5: do_set(sys.argv[2], sys.argv[3], sys.argv[4]); return
    fail('неизвестная команда или число аргументов')

if __name__=='__main__':
    main()
PY_TOML_TOOL
toml(){ python3 "$TOML_TOOL" "$@"; }

# --- backup ------------------------------------------------------------------
init_backup(){
  if [[ -n $BACKUP_DIR ]]; then return 0; fi
  BACKUP_DIR="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "$BACKUP_DIR" || die "Не удалось создать $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  printf '%s\n' "$BACKUP_DIR" > /var/lib/umbriel-noctalia-last-backup 2>/dev/null || true
  info "Резервные копии: $BACKUP_DIR"
  return 0
}
backup_path(){                       # $1 — источник, $2 — путь внутри backup
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
    if ! pkg_installed "$p"; then need+=("$p"); fi
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

  # Отключаем только неработающие cdrom-записи.
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

  # contrib/non-free/non-free-firmware только в стanzas официального архива Debian.
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
    || die "Не удалось скачать ключ Noctalia: $NOCTALIA_KEYRING_URL
Проверьте сеть/URL (можно переопределить через --keyring-url)."
  dpkg-deb --info "$TMP_DIR/keyring.deb" >/dev/null 2>&1 \
    || die 'Скачанный файл ключа не является .deb (возможно, прокси вернул HTML).'
  dpkg -i "$TMP_DIR/keyring.deb" || die 'Не удалось установить пакет ключа Noctalia.'

  info 'Установка описания репозитория Noctalia...'
  wget --https-only --timeout=60 --tries=3 -q "$NOCTALIA_SOURCES_URL" -O "$TMP_DIR/noctalia.sources" \
    || die "Не удалось скачать .sources: $NOCTALIA_SOURCES_URL (см. --sources-url)."
  grep -q '^Types:' "$TMP_DIR/noctalia.sources" && grep -q '^URIs:' "$TMP_DIR/noctalia.sources" \
    || die 'Скачанный .sources не похож на deb822-описание репозитория.'
  if grep -q '^Architectures:' "$TMP_DIR/noctalia.sources"; then
    grep -qE "^Architectures:.*(^|[[:space:]])${ARCH}([[:space:]]|$)" "$TMP_DIR/noctalia.sources" \
      || die "Репозиторий Noctalia не публикует пакеты для $ARCH."
  else
    warn 'В .sources нет поля Architectures; считаю, что доступны все архитектуры.'
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
    if [[ -z $c || $c == '(none)' ]]; then return 0; fi
  done
  if (( WITH_GREETER )); then
    c=$(apt_candidate noctalia-greeter)
    if [[ -z $c || $c == '(none)' ]]; then return 0; fi
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
  ensure_tools                       # python3 гарантирован ДО проверок TOML
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

if ! command -v python3 >/dev/null 2>&1; then
  if [[ $MODE == dry-run ]]; then
    warn 'python3 отсутствует: проверка TOML будет выполнена только при --install.'
  else
    die 'python3 недоступен.'
  fi
fi

# --- preflight существующего конфига ----------------------------------------
USER_CONFIG_DIR="$TARGET_HOME/.config/umbriel"
USER_CONFIG="$USER_CONFIG_DIR/config.toml"
INTEGRATION_CONFIG="$USER_CONFIG_DIR/noctalia-integration.toml"
if command -v python3 >/dev/null 2>&1 && [[ -f $USER_CONFIG ]]; then
  toml validate "$USER_CONFIG" || die "Существующий $USER_CONFIG невалиден; исправьте его вручную (backup будет сделан при --install)."
  debug 'preflight TOML пройден'
fi

# --- набор пакетов -----------------------------------------------------------
declare -A SEEN=()
PACKAGES=(); MISSING_PKGS=()
add_pkg(){ local p; for p in "$@"; do
    [[ -n $p ]] || continue
    if [[ ${SEEN[$p]+x} ]]; then continue; fi
    SEEN[$p]=1; PACKAGES+=("$p")
  done; return 0; }
add_available(){ local p; for p in "$@"; do
    if [[ ${SEEN[$p]+x} ]]; then continue; fi
    if apt_avail "$p"; then add_pkg "$p"; else MISSING_PKGS+=("$p"); warn "Пакет недоступен, пропущен: $p"; fi
  done; return 0; }

# Ядро: без этих пакетов установка невозможна.
CORE=(umbriel noctalia)
if (( WITH_GREETER )); then CORE+=(noctalia-greeter greetd); fi
for p in "${CORE[@]}"; do
  apt_avail "$p" || { apt_diagnostics; die "Обязательный пакет '$p' недоступен. Проверьте репозиторий Noctalia и trixie-backports."; }
  add_pkg "$p"
done

# Функционально необходимые компоненты (фильтруются, отсутствие — громкое предупреждение).
add_available \
  dbus dbus-user-session libpam-systemd \
  xdg-desktop-portal xdg-desktop-portal-gtk \
  polkitd pkexec \
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber \
  xwayland xdg-utils xdg-user-dirs kitty \
  qtwayland5 qt6-wayland qt5ct qt6ct libqt5svg5 libqt6svg6 \
  qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window \
  qml6-module-qt5compat-graphicaleffects qml-module-qtgraphicaleffects \
  libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers mesa-utils \
  accountsservice upower power-profiles-daemon \
  gvfs gvfs-backends gvfs-fuse \
  xauth x11-utils x11-xserver-utils locales man-db sudo \
  fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-noto-cjk \
  fonts-liberation2 fonts-jetbrains-mono \
  adwaita-icon-theme papirus-icon-theme \
  brightnessctl playerctl wl-clipboard

# Портал Umbriel: если его нет — пробуем совместимые.
if apt_avail xdg-desktop-portal-umbriel; then
  add_available xdg-desktop-portal-umbriel
else
  warn 'xdg-desktop-portal-umbriel недоступен; пробую xdg-desktop-portal-wlr/gtk.'
  add_available xdg-desktop-portal-wlr
fi

# Агент PolicyKit: нужен ровно один.
POLKIT_AGENT=''
for p in mate-polkit mate-polkit-bin polkit-kde-agent-1 lxpolkit; do
  if apt_avail "$p"; then POLKIT_AGENT=$p; break; fi
done
if [[ -n $POLKIT_AGENT ]]; then add_available "$POLKIT_AGENT"; else warn 'Агент PolicyKit не найден: аутентификация в GUI может не работать.'; fi

if (( ENABLE_BLUETOOTH )) || (( HAS_BT )); then add_available bluez libspa-0.2-bluetooth; fi
if (( ENABLE_NM )); then
  add_available network-manager
  warn 'NetworkManager будет включён; networking.service НЕ отключается.
Интерфейсы, описанные в /etc/network/interfaces, останутся под ifupdown (managed=false).'
fi

# Гостевые компоненты: по гипервизору, а не по наличию virtio-порта.
if (( ENABLE_VM_INTEGRATION )); then
  case "$VIRT" in
    qemu|kvm)
      add_available spice-vdagent qemu-guest-agent
      if [[ ! -e /dev/virtio-ports/com.redhat.spice.0 ]]; then
        warn 'SPICE-канал не виден (/dev/virtio-ports/com.redhat.spice.0).
spice-vdagent установлен, но для буфера обмена/авторазрешения добавьте SPICE-канал в конфиг VM.'
      fi ;;
    vmware)    add_available open-vm-tools open-vm-tools-desktop ;;
    oracle)    add_available virtualbox-guest-utils virtualbox-guest-x11 ;;
    microsoft) add_available hyperv-daemons ;;
    none)      warn '--enable-vm-integration указан, но гипервизор не обнаружен.' ;;
    *)         warn "Для гипервизора '$VIRT' пакеты не подобраны автоматически." ;;
  esac
fi

# Firmware по обнаруженному железу.
if (( ! SKIP_FIRMWARE )); then
  FW=()
  if (( GPU_INTEL )); then FW+=(firmware-intel-graphics intel-media-va-driver); fi
  if (( GPU_AMD ));   then FW+=(firmware-amd-graphics firmware-linux-nonfree); fi
  if (( GPU_NVIDIA )); then
    FW+=(firmware-nvidia-graphics)
    warn 'NVIDIA: проприетарный драйвер намеренно не устанавливается.'
  fi
  if [[ -n $NETWORK_INFO ]]; then FW+=(firmware-iwlwifi firmware-realtek firmware-atheros firmware-mediatek); fi
  if [[ $MACHINE_CLASS == laptop ]]; then FW+=(firmware-sof-signed); fi
  if ((${#FW[@]})); then add_available "${FW[@]}"; fi
fi

# Необязательные приложения и шрифты проекта.
if (( ! SKIP_OPTIONAL )); then
  add_available fonts-noctalia-tabler nautilus firefox-esr gnome-text-editor gnome-calculator \
    mpv mpv-mpris wdisplays ddcutil sound-theme-freedesktop fonts-noto-extra
fi

# --- версии ------------------------------------------------------------------
NOCTALIA_CAND=$(apt_candidate noctalia)
GREETER_CAND=''
if (( WITH_GREETER )); then GREETER_CAND=$(apt_candidate noctalia-greeter); fi
ver_check(){                        # $1 pkg, $2 candidate, $3 minimum
  local got; got=$(norm_version "$2")
  if dpkg --compare-versions "$got" ge "$3"; then return 0; fi
  if (( STRICT_VERSIONS )); then die "$1: кандидат $2 ниже требуемой $3 (--strict-versions)."; fi
  warn "$1: кандидат $2 ниже рекомендуемой $3; продолжаю."
  return 0
}
ver_check noctalia "$NOCTALIA_CAND" "$MIN_NOCTALIA"
if (( WITH_GREETER )); then ver_check noctalia-greeter "$GREETER_CAND" "$MIN_GREETER"; fi
for p in noctalia noctalia-greeter; do
  cand=$(apt_candidate "$p"); inst=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)
  if [[ -n $inst && -n $cand && $cand != '(none)' ]] && dpkg --compare-versions "$cand" lt "$inst"; then
    die "Кандидат $p ($cand) старее установленного ($inst): downgrade запрещён."
  fi
done

# --- target-release и план APT ----------------------------------------------
if [[ -n $TARGET_RELEASE ]] && ! have_release "$TARGET_RELEASE"; then
  warn "Release '$TARGET_RELEASE' недоступен в индексах; ставлю без target-release."
  TARGET_RELEASE=''
fi
APT_BASE=("${APT_OPTS[@]}")
if [[ -n $TARGET_RELEASE ]]; then APT_BASE+=(-t "$TARGET_RELEASE"); fi
if (( ! WITH_RECOMMENDS )); then APT_BASE+=(--no-install-recommends); fi
APT_ARGS=("${APT_BASE[@]}" install "${PACKAGES[@]}")

section 'PACKAGE PLAN'
printf '  %s\n' "${PACKAGES[@]}"
printf '\nTARGET-RELEASE: %s\nRECOMMENDS: %s\nNOCTALIA: %s\nGREETER: %s\n' \
  "${TARGET_RELEASE:-none}" "$( ((WITH_RECOMMENDS)) && echo yes || echo no)" \
  "$NOCTALIA_CAND" "${GREETER_CAND:-skipped}"
if ((${#MISSING_PKGS[@]})); then printf '\nПропущено (нет в репозиториях): %s\n' "${MISSING_PKGS[*]}"; fi

section 'APT SIMULATION'
SIM_FILE=$(mktemp "$TMP_DIR/apt-sim.XXXXXX")
if ! apt-get -s "${APT_ARGS[@]}" >"$SIM_FILE" 2>&1; then
  cat "$SIM_FILE" >&2
  apt_diagnostics
  die 'Симуляция APT не удалась. Система не изменена.'
fi
if (( VERBOSE )); then cat "$SIM_FILE"; else grep -E '^(Inst|Remv|Conf) ' "$SIM_FILE" | head -n 60 || true; fi

mapfile -t REMOVED < <(awk '/^Remv /{print $2}' "$SIM_FILE")
ALLOWED_REMV='^(pulseaudio|pulseaudio-utils|pulseaudio-module-bluetooth|pulseaudio-module-zeroconf|pulseaudio-module-gsettings|pipewire-media-session|xdg-desktop-portal-gnome)$'
BAD_REMV=()
for p in ${REMOVED[@]+"${REMOVED[@]}"}; do
  if [[ ! $p =~ $ALLOWED_REMV ]]; then BAD_REMV+=("$p"); fi
done
if ((${#REMOVED[@]})); then
  info "APT удаляет: ${REMOVED[*]}"
  info 'Штатное вытеснение PulseAudio через pipewire-pulse разрешено.'
fi
if ((${#BAD_REMV[@]})); then
  printf '  %s\n' "${BAD_REMV[@]}" >&2
  if (( ALLOW_REMOVALS )); then warn 'Удаления вне белого списка разрешены оператором (--allow-removals).'
  else die 'План APT удаляет пакеты вне белого списка. Отменено (см. --allow-removals).'; fi
fi
if grep -qE '^Inst .+ \[[^]]+\]' "$SIM_FILE"; then
  warn 'Часть установленных зависимостей будет обновлена (это не full-upgrade).'
fi
DM_NET_RE='^Inst (gdm3|lightdm|sddm|ly|lxdm|slim|xdm'
if (( ! ENABLE_NM )); then DM_NET_RE+='|network-manager'; fi
DM_NET_RE+='|ifupdown) '
if grep -qE "$DM_NET_RE" "$SIM_FILE"; then
  grep -E "$DM_NET_RE" "$SIM_FILE" >&2
  die 'План затрагивает чужой display manager или сетевой стек. Установка отменена.'
fi
for p in umbriel noctalia; do
  grep -qE "^Inst $p " "$SIM_FILE" || pkg_installed "$p" \
    || die "План APT не устанавливает обязательный пакет $p."
done

if [[ $MODE == dry-run ]]; then
  section 'DRY-RUN COMPLETE'
  printf 'Ничего не установлено и не изменено.\nДля установки: sudo %s --install [те же параметры]\n' "$PROGRAM"
  exit 0
fi

# --- конфликт display manager ------------------------------------------------
CURRENT_DM_UNIT=''
if command -v systemctl >/dev/null 2>&1; then
  DM_TARGET=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
  if [[ -n $DM_TARGET ]]; then CURRENT_DM_UNIT=$(basename "$DM_TARGET"); fi
  if (( WITH_GREETER )) && [[ -n $CURRENT_DM_UNIT && $CURRENT_DM_UNIT != greetd.service ]]; then
    if (( REPLACE_DM )); then
      warn "Текущий DM $CURRENT_DM_UNIT будет отключён (пакет/конфиги сохранятся, служба не останавливается)."
    else
      die "Выбран другой display manager ($CURRENT_DM_UNIT).
Автоматическое переключение запрещено. Решение: --replace-display-manager либо --no-greeter."
    fi
  fi
  DEFAULT_TARGET=$(systemctl get-default 2>/dev/null || true)
  case "$DEFAULT_TARGET" in
    graphical.target|multi-user.target|'') ;;
    *) warn "Неожиданный default target '$DEFAULT_TARGET'; автоматически менять не буду." ;;
  esac
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    die 'Занята блокировка APT/DPKG. Дождитесь завершения другой установки.'
  fi
fi

# --- backup перед изменениями ------------------------------------------------
init_backup
backup_path /etc/greetd 'etc/greetd'
backup_path /etc/systemd/system/display-manager.service 'etc/display-manager.service'
backup_path /etc/systemd/system/default.target 'etc/default.target'
backup_path /etc/default/locale 'etc/locale'
backup_path /etc/locale.gen 'etc/locale.gen'
for item in .config/umbriel .config/noctalia .config/kitty .config/autostart .config/systemd/user; do
  if [[ -e "$TARGET_HOME/$item" ]]; then backup_path "$TARGET_HOME/$item" "home/$item"; fi
done

# --- установка ---------------------------------------------------------------
section 'УСТАНОВКА ПАКЕТОВ'
if ! apt-get "${APT_ARGS[@]}"; then
  warn 'Единая транзакция не удалась. Пробую двухэтапную схему (как в v10).'
  REST=()
  for p in "${PACKAGES[@]}"; do if [[ $p != umbriel ]]; then REST+=("$p"); fi; done
  apt-get "${APT_BASE[@]}" install umbriel || { apt_diagnostics; die "Не удалось установить umbriel. Backup: $BACKUP_DIR"; }
  apt-get "${APT_BASE[@]}" install "${REST[@]}" || { apt_diagnostics; die "Не удалось установить остальные пакеты. Backup: $BACKUP_DIR"; }
fi

for p in umbriel noctalia; do
  pkg_installed "$p" || die "Пакет $p не установлен после транзакции."
  command -v "$p" >/dev/null 2>&1 || warn "Команда $p не найдена в PATH."
done
if [[ ! -d /usr/share/wayland-sessions ]] || ! ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1; then
  warn 'В /usr/share/wayland-sessions нет .desktop-файлов: сеанс может не появиться в greeter.'
fi

# --- локаль ------------------------------------------------------------------
CURRENT_LOCALE=$LOCALE_OVERRIDE
if [[ -z $CURRENT_LOCALE && -r /etc/default/locale ]]; then
  CURRENT_LOCALE=$(sed -n 's/^LANG=//p' /etc/default/locale | head -n1 | tr -d '"')
fi
[[ -n $CURRENT_LOCALE ]] || CURRENT_LOCALE=${LANG:-C.UTF-8}
if [[ $CURRENT_LOCALE == C || $CURRENT_LOCALE == POSIX ]]; then CURRENT_LOCALE=C.UTF-8; fi
if (( LOCALE_CHANGES )) && [[ $CURRENT_LOCALE != C.UTF-8 ]]; then
  if grep -qE "^${CURRENT_LOCALE}[[:space:]]+UTF-8$" /usr/share/i18n/SUPPORTED 2>/dev/null; then
    if ! grep -qE "^[[:space:]]*${CURRENT_LOCALE}[[:space:]]+UTF-8$" /etc/locale.gen 2>/dev/null; then
      printf '%s UTF-8\n' "$CURRENT_LOCALE" >> /etc/locale.gen
    else
      sed -i -E "s/^[[:space:]#]*(${CURRENT_LOCALE}[[:space:]]+UTF-8)/\1/" /etc/locale.gen
    fi
    locale-gen "$CURRENT_LOCALE" || warn "Не удалось сгенерировать локаль $CURRENT_LOCALE."
    update-locale "LANG=$CURRENT_LOCALE" || warn 'Не удалось записать системную локаль.'
  else
    warn "Локаль $CURRENT_LOCALE отсутствует в SUPPORTED; оставляю C.UTF-8."
    CURRENT_LOCALE=C.UTF-8
  fi
fi
info "Системная локаль: $CURRENT_LOCALE"
if (( ! SKIP_OPTIONAL )) && [[ $CURRENT_LOCALE != C.UTF-8 ]]; then
  LC_CODE=${CURRENT_LOCALE%%_*}
  L10N=()
  for p in "firefox-esr-l10n-$LC_CODE" "manpages-$LC_CODE" "hunspell-$LC_CODE" "aspell-$LC_CODE"; do
    if apt_avail "$p"; then L10N+=("$p"); fi
  done
  if ((${#L10N[@]})); then
    apt-get "${APT_BASE[@]}" install "${L10N[@]}" || warn 'Часть языковых пакетов не установлена.'
  fi
fi

# --- XKB ---------------------------------------------------------------------
KEYBOARD_LAYOUTS=''; KEYBOARD_OPTIONS=''; KEYBOARD_MODEL=''; KEYBOARD_VARIANT=''
if command -v localectl >/dev/null 2>&1; then
  XKB_STATUS=$(localectl status 2>/dev/null || true)
  KEYBOARD_LAYOUTS=$(sed -n 's/^ *X11 Layout: *//p' <<<"$XKB_STATUS" | head -n1)
  KEYBOARD_OPTIONS=$(sed -n 's/^ *X11 Options: *//p' <<<"$XKB_STATUS" | head -n1)
  KEYBOARD_MODEL=$(sed -n 's/^ *X11 Model: *//p' <<<"$XKB_STATUS" | head -n1)
  KEYBOARD_VARIANT=$(sed -n 's/^ *X11 Variant: *//p' <<<"$XKB_STATUS" | head -n1)
fi
for v in "$KEYBOARD_LAYOUTS" "$KEYBOARD_OPTIONS" "$KEYBOARD_MODEL" "$KEYBOARD_VARIANT"; do
  if [[ $v == '(none)' ]]; then v=''; fi
done
[[ $KEYBOARD_LAYOUTS == '(none)' ]] && KEYBOARD_LAYOUTS=''
[[ $KEYBOARD_OPTIONS == '(none)' ]] && KEYBOARD_OPTIONS=''
[[ $KEYBOARD_MODEL   == '(none)' ]] && KEYBOARD_MODEL=''
[[ $KEYBOARD_VARIANT == '(none)' ]] && KEYBOARD_VARIANT=''
[[ -n $KEYBOARD_LAYOUTS ]] || KEYBOARD_LAYOUTS=us
[[ -n $KEYBOARD_MODEL ]]   || KEYBOARD_MODEL=pc105
for pair in "layout:$KEYBOARD_LAYOUTS" "options:$KEYBOARD_OPTIONS" "model:$KEYBOARD_MODEL" "variant:$KEYBOARD_VARIANT"; do
  val=${pair#*:}
  [[ $val =~ ^[A-Za-z0-9_,:+-]*$ ]] || die "Недопустимое значение XKB (${pair%%:*}): '$val'"
done
info "XKB: layout=$KEYBOARD_LAYOUTS model=$KEYBOARD_MODEL variant='$KEYBOARD_VARIANT' options='$KEYBOARD_OPTIONS'"

# --- конфиг Umbriel ----------------------------------------------------------
section 'НАСТРОЙКА ПОЛЬЗОВАТЕЛЬСКОГО СЕАНСА'
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.config" "$USER_CONFIG_DIR"
if [[ ! -e $USER_CONFIG ]]; then
  [[ -r /usr/share/umbriel/config.toml ]] || die 'Пакет Umbriel не предоставил /usr/share/umbriel/config.toml.'
  install -m 0644 -o "$TARGET_USER" -g "$TARGET_GROUP" /usr/share/umbriel/config.toml "$USER_CONFIG"
  info 'Создан config.toml из штатного примера Umbriel.'
fi

# autostart: убираем второй агент PolicyKit, добавляем noctalia.
CUR_AUTOSTART=$(toml get "$USER_CONFIG" general.autostart 2>/dev/null || echo '[]')
AUTOSTART_JSON=$(python3 - "$CUR_AUTOSTART" <<'PY_AUTOSTART'
import json, sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
if not isinstance(a, list): a=[]
a=[x for x in a if isinstance(x,str) and x!='mate-polkit']
a=list(dict.fromkeys(a))
if 'noctalia' not in a: a.append('noctalia')
print(json.dumps(a, ensure_ascii=False))
PY_AUTOSTART
)

WRITE_INTEGRATION=1
if [[ -e $INTEGRATION_CONFIG ]]; then
  if toml validate "$INTEGRATION_CONFIG" >/dev/null 2>&1; then
    INC_AUTOSTART=$(toml get "$INTEGRATION_CONFIG" general.autostart 2>/dev/null || echo '[]')
    if grep -q '"noctalia"' <<<"$INC_AUTOSTART"; then
      WRITE_INTEGRATION=0
      info 'Существующий noctalia-integration.toml валиден и запускает Noctalia — не перезаписываю.'
    else
      warn 'Существующий noctalia-integration.toml не запускает Noctalia; перезаписываю (копия в backup).'
    fi
  else
    warn 'Существующий noctalia-integration.toml невалиден; перезаписываю (копия в backup).'
  fi
fi
if (( WRITE_INTEGRATION )); then
  cat > "$INTEGRATION_CONFIG" <<EOF_INTEGRATION
# Managed by $PROGRAM $SCRIPT_VERSION.
# Правьте этот файл для настройки интеграции; основной config.toml не меняется.

[general]
autostart = $AUTOSTART_JSON

[input.keyboard]
layout = "$KEYBOARD_LAYOUTS"
model = "$KEYBOARD_MODEL"
variant = "$KEYBOARD_VARIANT"
options = "$KEYBOARD_OPTIONS"

[keybinds]
"Mod+E" = "spawn nautilus"
"Mod+B" = "spawn firefox-esr"
"Mod+Shift+C" = "spawn noctalia msg panel-toggle control-center"
"XF86AudioRaiseVolume" = "spawn noctalia msg volume-up"
"XF86AudioLowerVolume" = "spawn noctalia msg volume-down"
"XF86AudioMute" = "spawn noctalia msg volume-mute"
"XF86MonBrightnessUp" = "spawn noctalia msg brightness-up"
"XF86MonBrightnessDown" = "spawn noctalia msg brightness-down"
EOF_INTEGRATION
  toml validate "$INTEGRATION_CONFIG" || die 'Сгенерированный integration-файл невалиден.'
fi

CUR_FILES=$(toml get "$USER_CONFIG" include.optional.files 2>/dev/null || echo '[]')
FILES_JSON=$(python3 - "$CUR_FILES" "$(basename "$INTEGRATION_CONFIG")" <<'PY_FILES'
import json, sys
try: f=json.loads(sys.argv[1])
except Exception: f=[]
if not isinstance(f, list): f=[]
f=[x for x in f if isinstance(x,str)]
if sys.argv[2] not in f: f.append(sys.argv[2])
print(json.dumps(f, ensure_ascii=False))
PY_FILES
)
toml set "$USER_CONFIG" include.optional.files "$FILES_JSON" \
  || die "Не удалось зарегистрировать include в $USER_CONFIG (файл не повреждён)."
chown "$TARGET_USER:$TARGET_GROUP" "$USER_CONFIG" "$INTEGRATION_CONFIG"
chmod 0644 "$USER_CONFIG" "$INTEGRATION_CONFIG"
info "Include зарегистрирован: $INTEGRATION_CONFIG"

# --- kitty -------------------------------------------------------------------
KITTY_DIR="$TARGET_HOME/.config/kitty"
KITTY_CONF="$KITTY_DIR/kitty.conf"
KITTY_EXTRA="$KITTY_DIR/umbriel-noctalia.conf"
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$KITTY_DIR"
{
  printf '# Managed by %s %s.\n' "$PROGRAM" "$SCRIPT_VERSION"
  if pkg_installed fonts-jetbrains-mono; then printf 'font_family JetBrains Mono\n'; fi
  cat <<'EOF_KITTY'
font_size 12.0
background_opacity 0.90
window_padding_width 10
confirm_os_window_close 0
map ctrl+shift+c copy_to_clipboard
map ctrl+shift+v paste_from_clipboard
EOF_KITTY
} > "$KITTY_EXTRA"
if [[ ! -e $KITTY_CONF ]]; then
  printf 'include %s\n' "$KITTY_EXTRA" > "$KITTY_CONF"
elif ! grep -Fq 'umbriel-noctalia.conf' "$KITTY_CONF"; then
  printf '\n# >>> Umbriel + Noctalia managed include >>>\ninclude %s\n# <<< Umbriel + Noctalia managed include <<<\n' "$KITTY_EXTRA" >> "$KITTY_CONF"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$KITTY_DIR"
chmod 0644 "$KITTY_EXTRA" "$KITTY_CONF"

# --- GNOME Keyring (opt-in) --------------------------------------------------
if (( DISABLE_KEYRING )); then
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" \
    "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.config/systemd/user"
  for f in /etc/xdg/autostart/gnome-keyring-*.desktop; do
    [[ -f $f ]] || continue
    name=$(basename "$f")
    override="$TARGET_HOME/.config/autostart/$name"
    backup_path "$override" "home/autostart/$name.pre"
    printf '[Desktop Entry]\nType=Application\nName=Disabled GNOME Keyring Autostart\nHidden=true\n' > "$override"
    chown "$TARGET_USER:$TARGET_GROUP" "$override"
  done
  for unit in gnome-keyring-daemon.service gnome-keyring-daemon.socket; do
    mask="$TARGET_HOME/.config/systemd/user/$unit"
    if [[ -L $mask && $(readlink "$mask") == /dev/null ]]; then continue; fi
    backup_path "$mask" "home/systemd-user/$unit.pre"
    rm -f -- "$mask"
    ln -s /dev/null "$mask"
    chown -h "$TARGET_USER:$TARGET_GROUP" "$mask"
  done
  warn 'GNOME Keyring отключён по запросу: сохранённые секреты могут стать недоступны приложениям.'
fi

# --- XDG-каталоги ------------------------------------------------------------
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" \
    LANG="$CURRENT_LOCALE" LC_ALL="$CURRENT_LOCALE" LANGUAGE="$CURRENT_LOCALE" \
    XDG_CONFIG_HOME="$TARGET_HOME/.config" xdg-user-dirs-update \
    || warn 'Не удалось обновить XDG-каталоги.'
fi

# --- валидация конфига Umbriel ----------------------------------------------
RUN_ENV=(HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config")
if [[ -S "/run/user/$TARGET_UID/bus" ]]; then
  RUN_ENV+=(XDG_RUNTIME_DIR="/run/user/$TARGET_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus")
fi
UMBRIEL_VALID=1
if ! runuser -u "$TARGET_USER" -- env "${RUN_ENV[@]}" umbriel config validate; then
  UMBRIEL_VALID=0
  warn 'umbriel config validate завершился ошибкой.'
fi

# --- службы ------------------------------------------------------------------
if [[ -d /run/systemd/system ]]; then
  if (( ENABLE_NM )); then
    systemctl enable NetworkManager.service >/dev/null 2>&1 || warn 'Не удалось включить NetworkManager.'
  fi
  systemctl enable power-profiles-daemon.service >/dev/null 2>&1 || true
  if (( ENABLE_BLUETOOTH )) || (( HAS_BT )); then
    systemctl enable bluetooth.service >/dev/null 2>&1 || warn 'Не удалось включить bluetooth.service.'
    # VM без адаптера: пустой /sys/class/bluetooth → unit пропускается,
    # а D-Bus-активация BlueZ блокирует Noctalia на ~25 секунд.
    if [[ -d /sys/class/bluetooth ]] && ! find /sys/class/bluetooth -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      BLUEZ_DROPIN_DIR=/etc/systemd/system/bluetooth.service.d
      backup_path "$BLUEZ_DROPIN_DIR/90-umbriel-noctalia.conf" 'etc/bluez-dropin.pre'
      install -d -m 0755 "$BLUEZ_DROPIN_DIR"
      printf '[Unit]\nConditionPathIsDirectory=\n' > "$BLUEZ_DROPIN_DIR/90-umbriel-noctalia.conf"
      systemctl daemon-reload || warn 'daemon-reload не удался.'
      systemctl restart bluetooth.service || warn 'bluetooth.service не запустился.'
      info 'BlueZ: снято условие пропуска при пустом /sys/class/bluetooth.'
    fi
  fi
else
  warn 'systemd не запущен: службы не включались.'
fi

# --- greetd ------------------------------------------------------------------
greetd_effective_config(){
  local line cfg='' d f
  if command -v systemctl >/dev/null 2>&1; then
    line=$(systemctl cat greetd.service 2>/dev/null | grep -E '^[[:space:]]*ExecStart=.+' | tail -n1 || true)
    if [[ -n $line ]]; then
      cfg=$(sed -nE 's/.*(-c|--config)[= ]+([^[:space:]]+).*/\2/p' <<<"$line" | tail -n1)
    fi
  fi
  if [[ -z $cfg ]]; then
    for d in /etc/systemd/system/greetd.service.d /usr/lib/systemd/system/greetd.service.d /lib/systemd/system/greetd.service.d; do
      [[ -d $d ]] || continue
      for f in "$d"/*.conf; do
        [[ -r $f ]] || continue
        cfg=$(sed -nE 's/.*(-c|--config)[= ]+([^[:space:]]+).*/\2/p' "$f" | tail -n1)
        if [[ -n $cfg ]]; then break; fi
      done
      if [[ -n $cfg ]]; then break; fi
    done
  fi
  cfg=${cfg%\"}; cfg=${cfg#\"}; cfg=${cfg%\'}; cfg=${cfg#\'}
  printf '%s\n' "${cfg:-/etc/greetd/config.toml}"
}

GREETER_ENABLED=0
if (( WITH_GREETER )); then
  section 'НАСТРОЙКА NOCTALIA GREETER'
  GREETER_SESSION=$(command -v noctalia-greeter-session 2>/dev/null || true)
  if [[ -z $GREETER_SESSION ]]; then
    warn 'Команда noctalia-greeter-session не найдена: greetd не включаю.'
  elif ! pkg_installed greetd; then
    warn 'Пакет greetd не установлен: greetd не включаю.'
  elif (( ! UMBRIEL_VALID )) && (( ! FORCE_GREETER )); then
    warn 'Конфиг Umbriel не прошёл валидацию: greetd не включаю (см. --force-greeter).'
  else
    GREETD_CONFIG=$(greetd_effective_config)
    info "Действующая конфигурация greetd: $GREETD_CONFIG"
    backup_path "$GREETD_CONFIG" "etc/$(basename "$GREETD_CONFIG").pre-noctalia"
    CUR_CMD=$(toml get "$GREETD_CONFIG" default_session.command 2>/dev/null || echo '""')
    if [[ $CUR_CMD != *noctalia-greeter-session* ]]; then
      toml set "$GREETD_CONFIG" default_session.command "$(json_str "$GREETER_SESSION")" \
        || die "Не удалось задать default_session.command в $GREETD_CONFIG."
      info 'default_session.command переключён на Noctalia Greeter.'
    else
      info 'default_session.command уже указывает на Noctalia Greeter.'
    fi
    if ! toml get "$GREETD_CONFIG" default_session.user >/dev/null 2>&1; then
      if getent passwd greeter >/dev/null 2>&1; then
        toml set "$GREETD_CONFIG" default_session.user '"greeter"' || warn 'Не удалось задать default_session.user.'
      else
        warn 'Пользователь greeter отсутствует и ключ user не задан; проверьте конфиг greetd вручную.'
      fi
    fi
    toml get "$GREETD_CONFIG" default_session.command | grep -q 'noctalia-greeter-session' \
      || die 'Проверка конфигурации greetd не пройдена.'
    if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
      noctalia-greeter-apply-appearance --setup-system \
        || warn 'Не удалось инициализировать состояние/тему greeter (--setup-system).'
    fi
    if [[ -d /run/systemd/system ]]; then
      if [[ -n $CURRENT_DM_UNIT && $CURRENT_DM_UNIT != greetd.service ]] && (( REPLACE_DM )); then
        systemctl disable "$CURRENT_DM_UNIT" || warn "Не удалось отключить $CURRENT_DM_UNIT."
      fi
      systemctl enable greetd.service || die 'Не удалось включить greetd.service.'
      if [[ $(systemctl get-default 2>/dev/null || true) == multi-user.target ]]; then
        systemctl set-default graphical.target || die 'Не удалось переключить default target на graphical.target.'
      fi
      GREETER_ENABLED=1
      info 'greetd включён; вход будет графическим после перезагрузки.'
    else
      warn 'systemd не запущен: greetd не включён.'
    fi
  fi
fi

# --- итог --------------------------------------------------------------------
section "УСТАНОВКА ЗАВЕРШЕНА (v$SCRIPT_VERSION)"
dpkg-query -W -f='  ${Package} ${Version} ${db:Status-Status}\n' \
  umbriel noctalia noctalia-greeter greetd xdg-desktop-portal-umbriel kitty 2>/dev/null || true
cat <<REPORT

Система:          ${PRETTY_NAME:-Debian} ($ARCH)
Устройство:       $MACHINE_CLASS / $VIRT
Пользователь:     $TARGET_USER ($TARGET_HOME)
Локаль:           $CURRENT_LOCALE
XKB layout:       $KEYBOARD_LAYOUTS
Target-release:   ${TARGET_RELEASE:-none}
Config Umbriel:   $USER_CONFIG
Integration:      $INTEGRATION_CONFIG
Kitty:            $KITTY_CONF
Umbriel validate: $( ((UMBRIEL_VALID)) && echo OK || echo FAILED)
Greeter включён:  $( ((GREETER_ENABLED)) && echo yes || echo no)
Backup:           $BACKUP_DIR
Log:              $LOG_FILE

Сочетания клавиш:
  Super+Enter    — Kitty (штатное Umbriel)
  Super          — Launcher Noctalia
  Super+E        — Nautilus
  Super+B        — Firefox ESR
  Super+Shift+C  — Control Center Noctalia

Проверьте перед перезагрузкой:
  umbriel config validate
  systemctl cat greetd.service
  cat $(greetd_effective_config 2>/dev/null || echo /etc/greetd/config.toml)
  ls -l /usr/share/wayland-sessions/
  systemctl is-enabled greetd.service; systemctl get-default

Перезагрузку скрипт НЕ выполняет. Сохраните работу и перезагрузитесь вручную.
Откат настроек: файлы из $BACKUP_DIR (пакеты вручную через apt).
REPORT
if ((${#MISSING_PKGS[@]})); then
  printf '\nНе установлено (отсутствовало в репозиториях): %s\n' "${MISSING_PKGS[*]}"
fi
if (( ! UMBRIEL_VALID )); then
  printf '\nВНИМАНИЕ: конфиг Umbriel не прошёл валидацию — исправьте его до перезагрузки.\n'
fi
if (( ! GREETER_ENABLED )) && (( WITH_GREETER )); then
  printf '\nВНИМАНИЕ: greetd не включён. Вход останется консольным, пока причина не устранена.\n'
fi