#!/usr/bin/env bash
# =============================================================================
#  install-umbriel-noctalia-debian13-v16.sh   —   версия 16.0.0
#  Umbriel + Noctalia v5 + Noctalia Greeter на Debian 13 (Trixie)
#  Сверено с docs.noctalia.dev и с индексами pkg.noctalia.dev.
#  Режимы: --report (по умолчанию) | --setup-repos | --dry-run | --install
#
#  Изменения v16 относительно v15 (все — исправления найденных багов):
#   • apt_candidate()/pkg_visible() больше не падают под set -e/pipefail при
#     отсутствии пакета — это был незакрытый остаток бага v11/v12.
#   • have_release() корректно распознаёт suite в URL и в release-строке.
#   • umbriel config validate: fallback на вызов без --json.
#   • python-сниппеты для autostart/include обёрнуты в if, чтобы ошибка
#     была диагностируемой.
#   • noctalia-greeter --print-greeter-user: fallback по существующим аккаунтам.
#   • Симуляция APT больше не обрезается до 50 строк.
#   • ERR-trap не шумит на финальном exit.
#   • default target multi-user → graphical теперь с явным warn.
#   • --greeter-default-user предупреждает, если инструмента синхронизации нет.
#   • SCRIPT_VERSION и имя файла в сообщениях больше не расходятся.
# =============================================================================
set -Eeuo pipefail
IFS=$' \n\t'
umask 022

SCRIPT_VERSION='16.0.0'
PROGRAM=${0##*/}

MODE=''; VERBOSE=0; TARGET_USER=''
ENABLE_BLUETOOTH=0; ENABLE_VM=0; ENABLE_NM=0
WITH_RECOMMENDS=1; ALLOW_REMOVALS=0; REPLACE_DM=0; WITH_GREETER=1
NO_REPO_CHANGES=0; SKIP_OPTIONAL=0; SKIP_FIRMWARE=0
LOCALE_CHANGES=1; LOCALE_OVERRIDE=''; XKB_LAYOUT_OVERRIDE=''
REPAIR_KEYRING=1; GREETER_DEFAULT_USER=0; STRICT_VERSIONS=0; FORCE_GREETER=0
TARGET_RELEASE='trixie-backports'
MIN_NOCTALIA='5.5.0'; MIN_GREETER='1.7.0'

KEYRING_URL='https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb'
SOURCES_URL='https://pkg.noctalia.dev/deb/noctalia-trixie.sources'
SOURCES_FILE='/etc/apt/sources.list.d/noctalia-trixie.sources'
BACKPORTS_FILE='/etc/apt/sources.list.d/debian-trixie-backports.sources'
NOCTALIA_DISTRO_DEFAULT='/etc/xdg/noctalia/10-umbriel-installer.toml'
LOG_FILE='/var/log/umbriel-noctalia-install.log'

BACKUP_DIR=''; TMP_DIR=''; SIM_FILE=''; TOML_TOOL=''
APT_OPTS=(-y -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_SUSPEND=1
export LC_ALL=C
unset LANGUAGE || true

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
err(){  printf '[ERROR] %s\n' "$*" >&2; }
die(){  err "$*"; exit 1; }
debug(){ if (( VERBOSE )); then printf '[DEBUG] %s\n' "$*" >&2; fi; return 0; }
section(){ printf '\n============================================================\n%s\n============================================================\n' "$*"; }

cleanup(){ local rc=$?; [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf -- "$TMP_DIR"; return "$rc"; }
trap cleanup EXIT
# Не печатаем ERR-trap для штатного "exit" из die()/веток — иначе шум в хвосте.
trap 'case "$BASH_COMMAND" in exit*|"exit $?") ;; *) err "Сбой: строка $LINENO, команда: $BASH_COMMAND" ;; esac' ERR

usage(){ cat <<EOF
$PROGRAM $SCRIPT_VERSION — Debian 13 Trixie (amd64/arm64)

  $PROGRAM --report                     диагностика, ничего не меняет
  sudo $PROGRAM --setup-repos           подключить репозитории и выйти
  $PROGRAM --dry-run [flags]            симуляция APT, ничего не меняет
  sudo $PROGRAM --install [flags]       установка (репозитории подключатся сами)

Флаги:
  --user USER               целевой пользователь (по умолчанию \$SUDO_USER)
  --enable-vm-integration   гостевые агенты по обнаруженному гипервизору
  --enable-bluetooth        BlueZ + Bluetooth-модуль PipeWire
  --enable-network-manager  NetworkManager (networking.service не отключается)
  --no-greeter              без Noctalia Greeter / greetd
  --replace-display-manager разрешить отключить текущий DM (пакеты не удаляются)
  --greeter-default-user    сделать USER выбранным по умолчанию на экране входа
  --no-recommends           не ставить Recommends (НЕ рекомендуется)
  --allow-removals          разрешить удаления пакетов вне белого списка
  --no-repo-changes         запретить правку источников APT
  --no-optional             без необязательных приложений
  --no-firmware             без firmware по железу
  --no-locale-changes       не трогать системную локаль
  --locale LOCALE           например ru_RU.UTF-8
  --xkb-layout LAYOUT       явно задать раскладку Umbriel (иначе — из localed)
  --no-keyring-repair       не снимать маскировки GNOME Keyring от v10
  --strict-versions         жёсткие пороги версий
  --force-greeter           включить greetd даже если config validate упал
  --target-release NAME     по умолчанию trixie-backports
  --keyring-url URL / --sources-url URL
  --verbose | -h, --help
EOF
}
take_value(){ [[ -n ${2:-} && ${2} != -* ]] || die "После $1 требуется значение (получено '${2:-}')."; }

while (($#)); do
  case "$1" in
    --report)      [[ -z $MODE ]] || die 'Укажите один режим.'; MODE=report ;;
    --setup-repos) [[ -z $MODE ]] || die 'Укажите один режим.'; MODE=setup-repos ;;
    --dry-run)     [[ -z $MODE ]] || die 'Укажите один режим.'; MODE=dry-run ;;
    --install)     [[ -z $MODE ]] || die 'Укажите один режим.'; MODE=install ;;
    --enable-vm-integration) ENABLE_VM=1 ;;
    --enable-bluetooth) ENABLE_BLUETOOTH=1 ;;
    --enable-network-manager) ENABLE_NM=1 ;;
    --no-greeter) WITH_GREETER=0 ;;
    --replace-display-manager) REPLACE_DM=1 ;;
    --greeter-default-user) GREETER_DEFAULT_USER=1 ;;
    --no-recommends) WITH_RECOMMENDS=0 ;;
    --allow-removals) ALLOW_REMOVALS=1 ;;
    --no-repo-changes) NO_REPO_CHANGES=1 ;;
    --no-optional) SKIP_OPTIONAL=1 ;;
    --no-firmware) SKIP_FIRMWARE=1 ;;
    --no-locale-changes) LOCALE_CHANGES=0 ;;
    --no-keyring-repair) REPAIR_KEYRING=0 ;;
    --strict-versions) STRICT_VERSIONS=1 ;;
    --force-greeter) FORCE_GREETER=1 ;;
    --verbose) VERBOSE=1 ;;
    --user) take_value "$1" "${2:-}"; TARGET_USER=$2; shift ;;
    --locale) take_value "$1" "${2:-}"; LOCALE_OVERRIDE=$2; shift ;;
    --xkb-layout) take_value "$1" "${2:-}"; XKB_LAYOUT_OVERRIDE=$2; shift ;;
    --target-release) take_value "$1" "${2:-}"; TARGET_RELEASE=$2; shift ;;
    --keyring-url) take_value "$1" "${2:-}"; KEYRING_URL=$2; shift ;;
    --sources-url) take_value "$1" "${2:-}"; SOURCES_URL=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
  shift
done
MODE=${MODE:-report}

for c in awk bash dpkg dpkg-query grep sed uname getent id install cp; do
  command -v "$c" >/dev/null 2>&1 || die "Не найдена команда: $c"
done
[[ -r /etc/os-release ]] || die 'Нет /etc/os-release.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] \
  || die "Нужен Debian 13 Trixie; обнаружено: ${PRETTY_NAME:-unknown}."
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64|arm64) ;; *) die "Архитектура $ARCH не поддерживается." ;; esac
if [[ $MODE == install || $MODE == setup-repos ]]; then
  [[ $EUID -eq 0 ]] || die "Для --$MODE нужен sudo."
  command -v apt-get >/dev/null 2>&1 || die 'Нет apt-get.'
fi
command -v apt-cache >/dev/null 2>&1 || die 'Нет apt-cache.'

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
  TARGET_GROUP=$(id -gn "$TARGET_USER"); TARGET_UID=$(id -u "$TARGET_USER")
  [[ -n $TARGET_HOME && -d $TARGET_HOME && $TARGET_HOME != / ]] || die "Некорректный HOME: '$TARGET_HOME'"
fi

VIRT=none; CONTAINER=none; CHASSIS=unknown
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt --vm 2>/dev/null || true); VIRT=${VIRT:-none}
  CONTAINER=$(systemd-detect-virt --container 2>/dev/null || true); CONTAINER=${CONTAINER:-none}
fi
if command -v hostnamectl >/dev/null 2>&1; then CHASSIS=$(hostnamectl chassis 2>/dev/null || true); fi
if [[ -z $CHASSIS || $CHASSIS == unknown ]] && [[ -r /sys/class/dmi/id/chassis_type ]]; then
  case "$(< /sys/class/dmi/id/chassis_type)" in
    8|9|10|14) CHASSIS=laptop ;; 3|4|5|6|7|15|16) CHASSIS=desktop ;;
  esac
fi
HAS_BATTERY=0
for p in /sys/class/power_supply/*; do
  [[ -r "$p/type" ]] || continue
  [[ $(<"$p/type") == Battery ]] && HAS_BATTERY=1
done
if [[ $VIRT != none || $CONTAINER != none ]]; then MACHINE_CLASS=virtual-machine
elif [[ $CHASSIS == laptop ]] || (( HAS_BATTERY )); then MACHINE_CLASS=laptop
elif [[ $CHASSIS == desktop ]]; then MACHINE_CLASS=desktop
else MACHINE_CLASS=physical-unknown; fi
PCI_LIST=''
command -v lspci >/dev/null 2>&1 && PCI_LIST=$(lspci -nn 2>/dev/null || true)
GPU_INFO=$(grep -Ei 'VGA compatible controller|3D controller|Display controller' <<<"$PCI_LIST" || true)
NETWORK_INFO=$(grep -Ei 'Ethernet controller|Network controller|Wireless' <<<"$PCI_LIST" || true)
AUDIO_INFO=$(grep -Ei 'Audio device|Multimedia audio controller' <<<"$PCI_LIST" || true)
GPU_INTEL=0; GPU_AMD=0; GPU_NVIDIA=0
grep -qi intel <<<"$GPU_INFO" && GPU_INTEL=1
grep -qiE 'AMD|ATI' <<<"$GPU_INFO" && GPU_AMD=1
grep -qi nvidia <<<"$GPU_INFO" && GPU_NVIDIA=1
HAS_WIFI=0; HAS_BT=0; CONNECTED_DRM=0
for p in /sys/class/net/*; do [[ -e "$p/wireless" || -e "$p/phy80211" ]] && HAS_WIFI=1; done
for p in /sys/class/bluetooth/*; do [[ -e "$p" ]] && HAS_BT=1; done
for p in /sys/class/drm/*/status; do
  [[ -r "$p" ]] || continue
  [[ $(<"$p") == connected ]] && CONNECTED_DRM=$((CONNECTED_DRM+1))
done
NETWORK_STACK=unknown
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then NETWORK_STACK=NetworkManager-active
  elif systemctl is-active --quiet networking.service 2>/dev/null; then NETWORK_STACK=networking-service-active
  elif [[ -f /etc/network/interfaces ]]; then NETWORK_STACK=ifupdown-config-present; fi
fi

# ---------- APT-хелперы (C-локаль, защита от pipefail) -----------------------
# apt-candidate не должен возвращать 100 для отсутствующего пакета: иначе
# `set -Eeuo pipefail` завершит скрипт при `c=$(apt_candidate ...)`.
apt_candidate(){ LC_ALL=C apt-cache policy "$1" 2>/dev/null \
  | awk '/^[[:space:]]*Candidate:/ {print $2; exit}' || true; }
pkg_visible(){
  local c; c=$(apt_candidate "$1" || true)
  [[ -n $c && $c != '(none)' ]] && return 0
  LC_ALL=C apt-cache show "$1" >/dev/null 2>&1
}
pkg_installed(){ dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }
# Suite может упоминаться в URL (`… trixie-backports/main …`) или в release-строке
# (`… n=trixie-backports,…`). Покрываем оба формата.
have_release(){
  LC_ALL=C apt-cache policy 2>/dev/null | grep -qE \
    "(^|[[:space:]])${1}([[:space:]]|/|$)|[[:space:]]n=${1}([[:space:]]|,|$)" || true
}
json_str(){ python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

section "UMBRIEL + NOCTALIA INSTALLER $SCRIPT_VERSION"
printf 'MODE: %s\nOS: %s\nARCH: %s\nKERNEL: %s\n' "$MODE" "${PRETTY_NAME:-Debian}" "$ARCH" "$(uname -r)"
printf 'MACHINE: %s | VIRT: %s | CONTAINER: %s | CHASSIS: %s\n' "$MACHINE_CLASS" "$VIRT" "$CONTAINER" "$CHASSIS"
printf 'BATTERY: %s | WI-FI: %s | BLUETOOTH: %s | DRM CONNECTED: %s\n' \
  "$( ((HAS_BATTERY)) && echo yes || echo no)" "$( ((HAS_WIFI)) && echo yes || echo no)" \
  "$( ((HAS_BT)) && echo yes || echo no)" "$CONNECTED_DRM"
printf 'NETWORK STACK: %s\n\nGPU:\n%s\nNETWORK:\n%s\nAUDIO:\n%s\n' "$NETWORK_STACK" \
  "${GPU_INFO:-  not detected}" "${NETWORK_INFO:-  not detected}" "${AUDIO_INFO:-  not detected}"
[[ -n $TARGET_USER ]] && printf '\nTARGET USER: %s\nHOME: %s\n' "$TARGET_USER" "$TARGET_HOME"
if command -v systemctl >/dev/null 2>&1; then
  printf '\nSERVICES:\n'
  for u in greetd.service display-manager.service NetworkManager.service networking.service bluetooth.service; do
    printf '  %-28s active=%-10s enabled=%s\n' "$u" \
      "$(systemctl is-active "$u" 2>/dev/null || true)" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
  done
fi
printf '\nAPT CANDIDATES:\n'
for p in umbriel noctalia noctalia-greeter greetd xdg-desktop-portal-umbriel fonts-noctalia-tabler; do
  printf '  %-30s %s\n' "$p" "$(apt_candidate "$p" || echo '?')"
done
printf '  %-30s %s\n' 'suite trixie-backports' "$(have_release trixie-backports && echo present || echo absent)"

if [[ $MODE == report ]]; then
  printf '\nREPORT COMPLETE; изменений нет.\nДальше: sudo %s --setup-repos | --dry-run | --install\n' "$PROGRAM"
  exit 0
fi
[[ -n $TARGET_USER ]] || die 'Не определён пользователь. Укажите --user USER.'
[[ $(id -u "$TARGET_USER") -ne 0 ]] || die 'Целевой пользователь не должен быть root.'
[[ $CONTAINER == none ]] || die "Контейнер '$CONTAINER': графический стек не устанавливается."

if [[ $MODE == install || $MODE == setup-repos ]]; then
  mkdir -p /var/log; exec > >(tee -a "$LOG_FILE") 2>&1
  info "Версия $SCRIPT_VERSION; журнал: $LOG_FILE"
fi
TMP_DIR=$(mktemp -d /tmp/umbriel-noctalia.XXXXXX)
TOML_TOOL="$TMP_DIR/toml_tool.py"

# ---------- TOML-редактор ----------------------------------------------------
cat > "$TOML_TOOL" <<'PY_TOML_TOOL'
#!/usr/bin/env python3
# toml_tool.py validate FILE | get FILE key.path | set FILE key.path JSON_VALUE
import json, os, re, sys, tempfile
from pathlib import Path
try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        print('[toml] required: Python 3.11+ (tomllib) or python3-tomli', file=sys.stderr); sys.exit(1)

BARE = re.compile(r'[A-Za-z0-9_-]+')
HEADER = re.compile(r'^[ \t]*\[([^\[\]]+)\][ \t]*$')
AOT = re.compile(r'^[ \t]*\[\[([^\[\]]+)\]\][ \t]*$')
ASSIGN = re.compile(r'^([ \t]*)([^=#]+?)[ \t]*=')

def fail(msg):
    print('[toml] ' + msg, file=sys.stderr); sys.exit(1)

def code_part(line):
    out = []; quote = None; i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == '\\' and quote == '"':
                if i + 1 < len(line):
                    out.append(line[i+1]); i += 2; continue
            elif ch == quote:
                quote = None
        elif ch == '"' or ch == "'":
            quote = ch; out.append(ch)
        elif ch == '#':
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out)

def strip_strings(code):
    out = []; i = 0; n = len(code)
    while i < n:
        ch = code[i]
        if ch == '"' or ch == "'":
            d3 = ch * 3
            if code.startswith(d3, i):
                j = code.find(d3, i + 3)
                if j == -1:
                    return ''.join(out), d3
                i = j + 3; continue
            q = ch; i += 1
            while i < n:
                if code[i] == '\\' and q == '"':
                    i += 2; continue
                if code[i] == q:
                    i += 1; break
                i += 1
            continue
        out.append(ch); i += 1
    return ''.join(out), None

def split_key(key):
    parts = []; cur = ''; quote = None; i = 0
    while i < len(key):
        ch = key[i]
        if quote:
            if ch == '\\' and quote == '"' and i + 1 < len(key):
                cur += key[i+1]; i += 2; continue
            if ch == quote:
                quote = None
            else:
                cur += ch
        elif ch == '"' or ch == "'":
            quote = ch
        elif ch == '.':
            parts.append(cur.strip()); cur = ''
        else:
            cur += ch
        i += 1
    parts.append(cur.strip())
    if not all(parts):
        fail('empty key segment in: ' + key)
    return parts

def render_key(parts):
    return '.'.join(p if BARE.fullmatch(p) else json.dumps(p, ensure_ascii=False) for p in parts)

def toml_inline(value):
    if isinstance(value, dict):
        return '{ ' + ', '.join(render_key([str(k)]) + ' = ' + toml_inline(v) for k, v in value.items()) + ' }'
    if isinstance(value, list):
        return '[' + ', '.join(toml_inline(v) for v in value) + ']'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return repr(value)
    fail('unsupported inline value type: ' + type(value).__name__)

def scan(lines):
    tables = []; records = []; table = ''; aot = False
    depth = 0; pending = None; triple = None
    for idx, raw in enumerate(lines):
        line = raw.rstrip('\n')
        if triple:
            if triple in line:
                triple = None
            continue
        code = code_part(line)
        bare, opener = strip_strings(code)
        if depth == 0 and pending is None and opener is None:
            m = AOT.match(code)
            if m:
                table = '.'.join(split_key(m.group(1))); aot = True
                tables.append({'name': table, 'index': idx, 'aot': True}); continue
            h = HEADER.match(code)
            if h:
                table = '.'.join(split_key(h.group(1))); aot = False
                tables.append({'name': table, 'index': idx, 'aot': False}); continue
            m = ASSIGN.match(code)
            if m and not aot:
                key = '.'.join(split_key(m.group(2)))
                path = table + '.' + key if table else key
                pending = {'path': path, 'lhs': m.group(2).strip(), 'indent': m.group(1), 'start': idx}
        if opener:
            triple = opener
        depth += bare.count('[') - bare.count(']') + bare.count('{') - bare.count('}')
        if pending is not None and depth <= 0:
            pending['end'] = idx; records.append(pending); pending = None; depth = 0
        if depth < 0:
            depth = 0
    return tables, records

def load(path):
    try:
        return tomllib.loads(Path(path).read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {}
    except Exception as exc:
        fail('%s: invalid TOML: %s' % (path, exc))

def dig(data, parts):
    cur = data
    for k in parts:
        if not isinstance(cur, dict) or k not in cur:
            return None, False
        cur = cur[k]
    return cur, True

def atomic_write(target, text, template=None):
    st = None
    for p in (target, template):
        if p is not None and p.exists():
            st = p.stat(); break
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=target.name + '.', suffix='.tmp', dir=str(target.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(text); fh.flush(); os.fsync(fh.fileno())
        if st is not None:
            os.chmod(tmp, st.st_mode & 0o7777)
            try:
                os.chown(tmp, st.st_uid, st.st_gid)
            except PermissionError:
                pass
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

def do_get(file_arg, keypath):
    p = Path(file_arg)
    if not p.exists():
        sys.exit(3)
    val, ok = dig(load(p), split_key(keypath))
    if not ok:
        sys.exit(3)
    print(json.dumps(val, ensure_ascii=False))

def do_set(file_arg, keypath, value_json):
    orig = Path(file_arg)
    target = orig.resolve() if orig.exists() else orig
    try:
        value = json.loads(value_json)
    except Exception as exc:
        fail('value is not JSON: %s' % exc)
    if not isinstance(value, (str, bool, int, float, list)):
        fail('unsupported value type')
    if isinstance(value, list) and not all(isinstance(x, str) for x in value):
        fail('arrays must contain strings only')
    parts = split_key(keypath)
    if len(parts) < 2:
        fail('key must look like section.key')
    raw = target.read_text(encoding='utf-8') if target.exists() else ''
    lines = raw.splitlines(keepends=True)
    tables, records = scan(lines)
    rendered = json.dumps(value, ensure_ascii=False)
    full = '.'.join(parts)
    rec = next((r for r in records if r['path'] == full), None)
    if rec is not None:
        lines[rec['start']:rec['end']+1] = ['%s%s = %s\n' % (rec['indent'], rec['lhs'], rendered)]
    else:
        placed = False
        data_old = load(target)
        for n in range(len(parts) - 1, 0, -1):
            anc = '.'.join(parts[:n])
            r = next((r for r in records if r['path'] == anc), None)
            if r is None:
                continue
            cur, ok = dig(data_old, parts[:n])
            if not ok or not isinstance(cur, dict):
                continue
            try:
                modified = json.loads(json.dumps(cur))
            except Exception:
                continue
            node = modified
            for k in parts[n:-1]:
                nxt = node.get(k)
                if nxt is None:
                    nxt = {}; node[k] = nxt
                if not isinstance(nxt, dict):
                    fail('cannot descend into non-table value at ' + k)
                node = nxt
            node[parts[-1]] = value
            lines[r['start']:r['end']+1] = ['%s%s = %s\n' % (r['indent'], r['lhs'], toml_inline(modified))]
            placed = True
            break
        if not placed:
            for n in range(len(parts) - 1, 0, -1):
                ancestor = '.'.join(parts[:n])
                t = next((t for t in tables if t['name'] == ancestor and not t['aot']), None)
                if t is not None:
                    lines.insert(t['index'] + 1, '%s = %s\n' % (render_key(parts[n:]), rendered))
                    placed = True; break
        if not placed:
            if lines and not lines[-1].endswith('\n'):
                lines[-1] += '\n'
            if lines:
                lines.append('\n')
            lines.append('[%s]\n' % render_key(parts[:-1]))
            lines.append('%s = %s\n' % (render_key(parts[-1:]), rendered))
    new = ''.join(lines)
    try:
        data = tomllib.loads(new)
    except Exception as exc:
        fail('result would be invalid TOML; file unchanged: %s' % exc)
    got, ok = dig(data, parts)
    if not ok or got != value:
        fail('semantic check failed; file unchanged')
    atomic_write(target, new, template=orig)

def main():
    if len(sys.argv) < 3:
        fail('not enough arguments')
    cmd = sys.argv[1]
    if cmd == 'validate' and len(sys.argv) == 3:
        load(sys.argv[2]); return
    if cmd == 'get' and len(sys.argv) == 4:
        do_get(sys.argv[2], sys.argv[3]); return
    if cmd == 'set' and len(sys.argv) == 5:
        do_set(sys.argv[2], sys.argv[3], sys.argv[4]); return
    fail('unknown command or wrong argument count')

main()
PY_TOML_TOOL
toml(){ python3 "$TOML_TOOL" "$@"; }

init_backup(){
  [[ -n $BACKUP_DIR ]] && return 0
  BACKUP_DIR="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"
  mkdir -p -- "$BACKUP_DIR" || die "Не создать $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  printf '%s\n' "$BACKUP_DIR" > /var/lib/umbriel-noctalia-last-backup 2>/dev/null || true
  info "Резервные копии: $BACKUP_DIR"; return 0
}
backup_path(){
  local src=$1 dst="$BACKUP_DIR/$2"
  [[ -e $src || -L $src ]] || return 0
  mkdir -p -- "$(dirname -- "$dst")" || die "Не создать каталог backup для $src"
  cp -a -- "$src" "$dst" || die "Backup $src не удался — остановка до изменений."
  debug "backup: $src -> $dst"; return 0
}
ensure_tools(){
  local need=() p
  for p in ca-certificates curl wget gnupg python3 pciutils; do
    pkg_installed "$p" || need+=("$p")
  done
  if ((${#need[@]})); then
    info "Базовые инструменты: ${need[*]}"
    apt-get "${APT_OPTS[@]}" install "${need[@]}" || die 'Не удалось поставить базовые инструменты.'
  fi
  return 0
}
debian_backports_present(){
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f $f ]] || continue
    grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*debian\.org.*[[:space:]]trixie-backports([[:space:]]|$)' "$f" && return 0
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f $f && $f != "$BACKPORTS_FILE" ]] || continue
    grep -Eq '^Suites:.*(^|[[:space:]])trixie-backports([[:space:]]|$)' "$f" \
      && grep -Eq '^URIs:.*https?://([a-z]+\.)?debian\.org/' "$f" && return 0
  done
  return 1
}
setup_repos(){
  init_backup; section 'ПОДКЛЮЧЕНИЕ РЕПОЗИТОРИЕВ'
  backup_path /etc/apt/sources.list 'apt/sources.list'
  backup_path /etc/apt/sources.list.d 'apt/sources.list.d'
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f $f ]] || continue
    if grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' "$f"; then
      sed -i -E 's/^([[:space:]]*deb[[:space:]]+)cdrom:/#\1cdrom:/' "$f" || die "cdrom-запись в $f не отключена"
      info "Отключена cdrom-запись: $f"
    fi
  done
  apt-get "${APT_OPTS[@]}" update || warn 'Первичный apt update с ошибкой; продолжаю.'
  ensure_tools
  if debian_backports_present; then
    info 'Debian trixie-backports уже подключён.'
  elif [[ ! -f $BACKPORTS_FILE ]]; then
    cat > "$BACKPORTS_FILE" <<'EOF_BP'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_BP
    info 'Добавлен Debian trixie-backports.'
  fi
  info 'Ключ репозитория Noctalia...'
  wget --https-only --timeout=60 --tries=3 -q "$KEYRING_URL" -O "$TMP_DIR/keyring.deb" \
    || die "Не скачан ключ: $KEYRING_URL (см. --keyring-url)."
  dpkg-deb --info "$TMP_DIR/keyring.deb" >/dev/null 2>&1 || die 'Файл ключа не является .deb.'
  dpkg -i "$TMP_DIR/keyring.deb" || die 'Ключ Noctalia не установлен.'
  info 'Описание репозитория Noctalia...'
  wget --https-only --timeout=60 --tries=3 -q "$SOURCES_URL" -O "$TMP_DIR/noctalia.sources" \
    || die "Не скачан .sources: $SOURCES_URL (см. --sources-url)."
  grep -q '^Types:' "$TMP_DIR/noctalia.sources" && grep -q '^URIs:' "$TMP_DIR/noctalia.sources" \
    || die 'Скачанный файл не похож на deb822 .sources.'
  grep -q '^Suites:.*trixie-backports' "$TMP_DIR/noctalia.sources" \
    || warn 'В .sources нет suite trixie-backports — umbriel/greeter могут быть недоступны.'
  if grep -q '^Architectures:' "$TMP_DIR/noctalia.sources" \
     && ! grep -qE "^Architectures:.*(^|[[:space:]])${ARCH}([[:space:]]|$)" "$TMP_DIR/noctalia.sources"; then
    if [[ $ARCH == arm64 ]]; then
      sed -i -E "s/^Architectures:.*/& ${ARCH}/" "$TMP_DIR/noctalia.sources"
      warn "В .sources не было $ARCH; добавлена (Release репозитория публикует arm64)."
    else
      die "Репозиторий не публикует $ARCH."
    fi
  fi
  backup_path "$SOURCES_FILE" 'apt/noctalia-trixie.sources.pre'
  install -m 0644 "$TMP_DIR/noctalia.sources" "$SOURCES_FILE"
  apt-get "${APT_OPTS[@]}" update || die 'apt update после подключения Noctalia не удался.'
  info 'Репозитории подключены.'; return 0
}
repos_needed(){
  local p
  for p in umbriel noctalia; do pkg_visible "$p" || return 0; done
  if (( WITH_GREETER )); then pkg_visible noctalia-greeter || return 0; fi
  return 1
}
apt_diagnostics(){
  warn '--- Диагностика APT ---'
  LC_ALL=C apt-cache policy umbriel noctalia noctalia-greeter greetd fonts-noctalia-tabler \
    xdg-desktop-portal-umbriel libwlroots-0.20 libxkbcommon0 libdrm2 libinput10 libdisplay-info3 2>/dev/null || true
  warn 'Поиск пакетов проекта:'
  LC_ALL=C apt-cache search --names-only 'noctalia|umbriel' 2>/dev/null || true
  local held; held=$(apt-mark showhold 2>/dev/null || true)
  [[ -z $held ]] || { warn 'apt-mark hold:'; printf '%s\n' "$held" >&2; }
  grep -RniE 'noctalia|trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null >&2 || true
  return 0
}

if [[ $MODE == setup-repos ]]; then
  setup_repos; section 'РЕПОЗИТОРИИ ГОТОВЫ'
  for p in umbriel noctalia noctalia-greeter; do printf '  %-22s %s\n' "$p" "$(apt_candidate "$p")"; done
  printf '\nДальше: %s --dry-run, затем sudo %s --install\n' "$PROGRAM" "$PROGRAM"
  exit 0
fi
if [[ $MODE == install ]]; then
  ensure_tools
  if repos_needed; then
    if (( NO_REPO_CHANGES )); then
      apt_diagnostics; die "Пакетов нет в APT, а --no-repo-changes запрещает правку. Выполните: sudo $PROGRAM --setup-repos"
    fi
    setup_repos
  else
    info 'Пакеты проекта уже видны в APT; источники не меняю.'
    apt-get "${APT_OPTS[@]}" update || warn 'apt update с ошибкой; использую текущие индексы.'
  fi
fi
if ! command -v python3 >/dev/null 2>&1; then
  [[ $MODE == dry-run ]] || die 'python3 недоступен.'
  warn 'python3 нет: проверка TOML будет выполнена только при --install.'
fi
USER_CONFIG_DIR="$TARGET_HOME/.config/umbriel"
USER_CONFIG="$USER_CONFIG_DIR/config.toml"
INTEGRATION_CONFIG="$USER_CONFIG_DIR/noctalia-integration.toml"
if command -v python3 >/dev/null 2>&1 && [[ -f $USER_CONFIG ]]; then
  toml validate "$USER_CONFIG" || die "Существующий $USER_CONFIG невалиден — исправьте вручную."
fi

# ------------------------------- набор пакетов -------------------------------
declare -A SEEN=(); PACKAGES=(); MISSING_PKGS=()
add_pkg(){ local p; for p in "$@"; do [[ -n $p ]] || continue
    [[ ${SEEN[$p]+x} ]] && continue; SEEN[$p]=1; PACKAGES+=("$p"); done; return 0; }
add_avail(){ local p; for p in "$@"; do
    [[ ${SEEN[$p]+x} ]] && continue
    if pkg_visible "$p"; then add_pkg "$p"; else MISSING_PKGS+=("$p"); warn "Недоступен, пропущен: $p"; fi
  done; return 0; }

CORE=(umbriel noctalia)
(( WITH_GREETER )) && CORE+=(noctalia-greeter)
for p in "${CORE[@]}"; do
  pkg_visible "$p" || { apt_diagnostics; die "Обязательный пакет '$p' недоступен (репозиторий Noctalia / trixie-backports)."; }
  add_pkg "$p"
done
add_avail xdg-desktop-portal-umbriel
# Noctalia v5 — нативный шелл (EGL/GLES + cairo/pango). Qt/QML не нужны.
add_avail \
  dbus dbus-user-session libpam-systemd \
  xdg-desktop-portal xdg-desktop-portal-gtk \
  polkitd pkexec \
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber \
  xwayland libxcb-shape0 xdg-utils xdg-user-dirs kitty \
  fontconfig fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-liberation2 \
  hicolor-icon-theme adwaita-icon-theme \
  gnome-keyring libsecret-1-0 accountsservice \
  libegl1 libgles2 libegl-mesa0 libgl1-mesa-dri \
  libheif1 libheif-plugin-dav1d libheif-plugin-libde265 \
  sound-theme-freedesktop git curl ca-certificates locales
if (( ENABLE_BLUETOOTH )) || (( HAS_BT )); then add_avail bluez libspa-0.2-bluetooth; fi
if (( ENABLE_NM )); then
  add_avail network-manager
  warn 'NetworkManager будет включён; networking.service НЕ отключается (managed=false).'
fi
if (( ENABLE_VM )); then
  case "$VIRT" in
    qemu|kvm) add_avail spice-vdagent qemu-guest-agent
      [[ -e /dev/virtio-ports/com.redhat.spice.0 ]] || warn 'SPICE-канал не виден: добавьте его в конфиг VM для буфера обмена.' ;;
    vmware) add_avail open-vm-tools open-vm-tools-desktop ;;
    oracle) add_avail virtualbox-guest-utils virtualbox-guest-x11 ;;
    microsoft) add_avail hyperv-daemons ;;
    none) warn '--enable-vm-integration указан, но гипервизор не обнаружен.' ;;
    *) warn "Гипервизор '$VIRT': пакеты не подобраны." ;;
  esac
fi
if (( ! SKIP_FIRMWARE )) && [[ $MACHINE_CLASS != virtual-machine ]]; then
  FW=()
  (( GPU_INTEL )) && FW+=(firmware-intel-graphics intel-media-va-driver)
  (( GPU_AMD )) && FW+=(firmware-amd-graphics)
  (( GPU_NVIDIA )) && { FW+=(firmware-nvidia-graphics); warn 'NVIDIA: проприетарный драйвер не ставится.'; }
  [[ -n $NETWORK_INFO ]] && FW+=(firmware-iwlwifi firmware-realtek firmware-atheros firmware-mediatek)
  [[ $MACHINE_CLASS == laptop ]] && FW+=(firmware-sof-signed)
  ((${#FW[@]})) && add_avail "${FW[@]}"
fi
if (( ! SKIP_OPTIONAL )); then
  add_avail upower power-profiles-daemon ddcutil brightnessctl playerctl wl-clipboard \
    mesa-utils mesa-vulkan-drivers papirus-icon-theme fonts-noto-cjk fonts-jetbrains-mono \
    seahorse gvfs gvfs-backends gvfs-fuse \
    nautilus firefox-esr gnome-text-editor gnome-calculator mpv mpv-mpris wdisplays \
    x11-utils x11-xserver-utils xauth xinit man-db
fi

# --------------------------------- версии -----------------------------------
ver_check(){ local got=${2#*:}
  if dpkg --compare-versions "$got" ge "$3"; then return 0; fi
  if (( STRICT_VERSIONS )); then die "$1: $2 < $3 (--strict-versions)."; fi
  warn "$1: кандидат $2 ниже рекомендуемой $3; продолжаю."; return 0; }
NOCTALIA_CAND=$(apt_candidate noctalia || true); GREETER_CAND=''
[[ -z $NOCTALIA_CAND ]] || ver_check noctalia "$NOCTALIA_CAND" "$MIN_NOCTALIA"
if (( WITH_GREETER )); then
  GREETER_CAND=$(apt_candidate noctalia-greeter || true)
  [[ -z $GREETER_CAND ]] || ver_check noctalia-greeter "$GREETER_CAND" "$MIN_GREETER"
fi
for p in noctalia noctalia-greeter umbriel; do
  cand=$(apt_candidate "$p" || true); inst=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)
  if [[ -n $inst && -n $cand && $cand != '(none)' ]] && dpkg --compare-versions "$cand" lt "$inst"; then
    die "Кандидат $p ($cand) старее установленного ($inst): downgrade запрещён."
  fi
done

# ------------------------------ план и симуляция -----------------------------
if [[ -n $TARGET_RELEASE ]] && ! have_release "$TARGET_RELEASE"; then
  warn "Release '$TARGET_RELEASE' не найден в индексах; ставлю без target-release."
  TARGET_RELEASE=''
fi
APT_BASE=("${APT_OPTS[@]}")
[[ -z $TARGET_RELEASE ]] || APT_BASE+=(-t "$TARGET_RELEASE")
(( WITH_RECOMMENDS )) || APT_BASE+=(--no-install-recommends)
APT_ARGS=("${APT_BASE[@]}" install "${PACKAGES[@]}")

section 'PACKAGE PLAN'; printf '  %s\n' "${PACKAGES[@]}"
printf '\nTARGET-RELEASE: %s | RECOMMENDS: %s\nNOCTALIA: %s | GREETER: %s\n' \
  "${TARGET_RELEASE:-none}" "$( ((WITH_RECOMMENDS)) && echo yes || echo no)" \
  "$NOCTALIA_CAND" "${GREETER_CAND:-skipped}"
((${#MISSING_PKGS[@]})) && printf '\nПропущено (нет в репозиториях): %s\n' "${MISSING_PKGS[*]}"

section 'APT SIMULATION'
SIM_FILE=$(mktemp "$TMP_DIR/apt-sim.XXXXXX")
if ! apt-get -s "${APT_ARGS[@]}" >"$SIM_FILE" 2>&1; then
  cat "$SIM_FILE" >&2; apt_diagnostics; die 'Симуляция APT не удалась. Система не изменена.'
fi
if (( VERBOSE )); then
  cat "$SIM_FILE"
else
  # Показываем все Inst/Remv: обрезка до 50 строк скрывала бы диагностику
  # конфликтов версий (libdrm2/libxkbcommon0/libinput10), которые важны.
  grep -E '^(Inst|Remv) ' "$SIM_FILE" || true
fi
mapfile -t REMOVED < <(awk '/^Remv /{print $2}' "$SIM_FILE")
ALLOWED_REMV='^(pulseaudio|pulseaudio-utils|pulseaudio-module-bluetooth|pulseaudio-module-zeroconf|pulseaudio-module-gsettings|pipewire-media-session|xdg-desktop-portal-gnome)$'
BAD_REMV=()
for p in ${REMOVED[@]+"${REMOVED[@]}"}; do [[ $p =~ $ALLOWED_REMV ]] || BAD_REMV+=("$p"); done
((${#REMOVED[@]})) && info "APT удаляет: ${REMOVED[*]}"
if ((${#BAD_REMV[@]})); then
  printf '  %s\n' "${BAD_REMV[@]}" >&2
  if (( ALLOW_REMOVALS )); then warn 'Удаления разрешены оператором.'
  else die 'План удаляет пакеты вне белого списка (см. --allow-removals).'; fi
fi
DM_NET_RE='^Inst (gdm3|lightdm|sddm|ly|lxdm|slim|xdm'
(( ENABLE_NM )) || DM_NET_RE+='|network-manager'
DM_NET_RE+='|ifupdown) '
if grep -qE "$DM_NET_RE" "$SIM_FILE"; then
  grep -E "$DM_NET_RE" "$SIM_FILE" >&2
  die 'План затрагивает чужой display manager или сетевой стек.'
fi
for p in umbriel noctalia; do
  grep -qE "^Inst $p " "$SIM_FILE" || pkg_installed "$p" || die "План не устанавливает $p."
done
if [[ $MODE == dry-run ]]; then
  section 'DRY-RUN COMPLETE'
  printf 'Ничего не изменено.\nУстановка: sudo %s --install [те же флаги]\n' "$PROGRAM"
  exit 0
fi

# ------------------------- display manager / локи ----------------------------
CURRENT_DM_UNIT=''
if command -v systemctl >/dev/null 2>&1; then
  DM_TARGET=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
  [[ -z $DM_TARGET ]] || CURRENT_DM_UNIT=$(basename "$DM_TARGET")
  if (( WITH_GREETER )) && [[ -n $CURRENT_DM_UNIT && $CURRENT_DM_UNIT != greetd.service ]]; then
    if (( REPLACE_DM )); then warn "$CURRENT_DM_UNIT будет отключён (пакет и конфиги сохраняются)."
    else die "Выбран другой DM ($CURRENT_DM_UNIT). Решение: --replace-display-manager либо --no-greeter."; fi
  fi
  case "$(systemctl get-default 2>/dev/null || true)" in
    graphical.target|multi-user.target|'') ;;
    *) warn 'Неожиданный default target; автоматически не меняю.' ;;
  esac
  if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    die 'Занята блокировка APT/DPKG.'
  fi
fi
for p in dunst mako swaync; do
  pkg_installed "$p" && warn "$p установлен: Noctalia сам занимает org.freedesktop.Notifications — отключите второй демон уведомлений."
done
pkg_installed mate-polkit && warn 'mate-polkit установлен (остался с v10). Используется встроенный агент Noctalia; второй агент не нужен.'

init_backup
backup_path /etc/greetd 'etc/greetd'
backup_path /etc/systemd/system/display-manager.service 'etc/display-manager.service'
backup_path /etc/systemd/system/default.target 'etc/default.target'
backup_path /etc/default/locale 'etc/locale'
backup_path /etc/locale.gen 'etc/locale.gen'
backup_path /etc/pam.d/greetd 'etc/pam.d/greetd'
backup_path "$NOCTALIA_DISTRO_DEFAULT" 'etc/xdg/noctalia/10-umbriel-installer.toml'
for item in .config/umbriel .config/noctalia .config/kitty .config/autostart .config/systemd/user; do
  [[ -e "$TARGET_HOME/$item" ]] && backup_path "$TARGET_HOME/$item" "home/$item"
done

section 'УСТАНОВКА ПАКЕТОВ'
if ! apt-get "${APT_ARGS[@]}"; then
  warn 'Единая транзакция не удалась; пробую двухэтапно (как v10).'
  REST=(); for p in "${PACKAGES[@]}"; do [[ $p == umbriel ]] || REST+=("$p"); done
  apt-get "${APT_BASE[@]}" install umbriel || { apt_diagnostics; die "umbriel не установлен. Backup: $BACKUP_DIR"; }
  apt-get "${APT_BASE[@]}" install "${REST[@]}" || { apt_diagnostics; die "Остальные пакеты не установлены. Backup: $BACKUP_DIR"; }
fi
for p in umbriel noctalia; do
  pkg_installed "$p" || die "Пакет $p не установлен."
  command -v "$p" >/dev/null 2>&1 || warn "Команда $p не в PATH."
done
compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null \
  || warn 'Нет .desktop в /usr/share/wayland-sessions.'

# ---------------------------------- локаль ----------------------------------
CURRENT_LOCALE=$LOCALE_OVERRIDE
if [[ -z $CURRENT_LOCALE && -r /etc/default/locale ]]; then
  CURRENT_LOCALE=$(sed -n 's/^LANG=//p' /etc/default/locale | head -n1 | tr -d '"')
fi
[[ -n $CURRENT_LOCALE ]] || CURRENT_LOCALE=${LANG:-C.UTF-8}
[[ $CURRENT_LOCALE == C || $CURRENT_LOCALE == POSIX ]] && CURRENT_LOCALE=C.UTF-8
if (( LOCALE_CHANGES )) && [[ $CURRENT_LOCALE != C.UTF-8 ]]; then
  if grep -qE "^${CURRENT_LOCALE}[[:space:]]+UTF-8$" /usr/share/i18n/SUPPORTED 2>/dev/null; then
    if grep -qE "^[[:space:]#]*${CURRENT_LOCALE}[[:space:]]+UTF-8" /etc/locale.gen 2>/dev/null; then
      sed -i -E "s/^[[:space:]#]*(${CURRENT_LOCALE}[[:space:]]+UTF-8)/\1/" /etc/locale.gen
    else
      printf '%s UTF-8\n' "$CURRENT_LOCALE" >> /etc/locale.gen
    fi
    locale-gen "$CURRENT_LOCALE" || warn "locale-gen $CURRENT_LOCALE не удался."
    update-locale "LANG=$CURRENT_LOCALE" || warn 'update-locale не удался.'
  else
    warn "Локаль $CURRENT_LOCALE не поддерживается; оставляю C.UTF-8."; CURRENT_LOCALE=C.UTF-8
  fi
fi
info "Локаль: $CURRENT_LOCALE"
XKB_LAYOUTS_NOW=''
if command -v localectl >/dev/null 2>&1; then
  XKB_LAYOUTS_NOW=$(localectl status 2>/dev/null | sed -n 's/^ *X11 Layout: *//p' | head -n1)
  [[ $XKB_LAYOUTS_NOW == '(none)' ]] && XKB_LAYOUTS_NOW=''
fi

# ------------------------- конфигурация Umbriel ------------------------------
section 'НАСТРОЙКА СЕАНСА UMBRIEL'
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.config" "$USER_CONFIG_DIR"
if [[ ! -e $USER_CONFIG ]]; then
  [[ -r /usr/share/umbriel/config.toml ]] || die 'Пакет umbriel не дал /usr/share/umbriel/config.toml.'
  install -m 0644 -o "$TARGET_USER" -g "$TARGET_GROUP" /usr/share/umbriel/config.toml "$USER_CONFIG"
  info 'config.toml создан из штатного примера Umbriel.'
fi
# include применяется первым, основной config.toml — последним.
MAIN_AUTOSTART=$(toml get "$USER_CONFIG" general.autostart 2>/dev/null || true)
MAIN_KEYBINDS=0
toml get "$USER_CONFIG" keybinds >/dev/null 2>&1 && MAIN_KEYBINDS=1
INCLUDE_AUTOSTART=1
if [[ -n $MAIN_AUTOSTART ]]; then
  if ! NEW_AUTOSTART=$(python3 - "$MAIN_AUTOSTART" <<'PY_AS'
import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
a=[x for x in a if isinstance(x,str) and x!='mate-polkit']
a=list(dict.fromkeys(a))
if 'noctalia' not in a: a.append('noctalia')
print(json.dumps(a,ensure_ascii=False))
PY_AS
  ); then
    warn 'Не удалось нормализовать general.autostart; оставляю как есть.'
    NEW_AUTOSTART="$MAIN_AUTOSTART"
  fi
  toml set "$USER_CONFIG" general.autostart "$NEW_AUTOSTART" || die 'Не удалось обновить general.autostart.'
  INCLUDE_AUTOSTART=0
  info 'general.autostart обновлён в основном config.toml (он имеет приоритет над include).'
fi
WRITE_INC=1
if [[ -e $INTEGRATION_CONFIG ]]; then
  if grep -q 'Managed by install-umbriel-noctalia' "$INTEGRATION_CONFIG"; then
    info 'Пересоздаю свой integration-файл (копия в backup).'
  elif toml validate "$INTEGRATION_CONFIG" >/dev/null 2>&1 \
       && toml get "$INTEGRATION_CONFIG" general.autostart 2>/dev/null | grep -q '"noctalia"'; then
    WRITE_INC=0; info 'Существующий noctalia-integration.toml валиден и запускает Noctalia — не трогаю.'
  else
    warn 'Существующий noctalia-integration.toml не запускает Noctalia/невалиден — пересоздаю (копия в backup).'
  fi
fi
if (( WRITE_INC )); then
  {
    printf '# Managed by %s %s.\n' "$PROGRAM" "$SCRIPT_VERSION"
    printf '# Правьте этот файл: основной config.toml не перезаписывается.\n\n'
    if (( INCLUDE_AUTOSTART )); then printf '[general]\nautostart = ["noctalia"]\n\n'; fi
    if [[ -n $XKB_LAYOUT_OVERRIDE ]]; then
      [[ $XKB_LAYOUT_OVERRIDE =~ ^[A-Za-z0-9_,:+-]+$ ]] || die 'Недопустимое значение --xkb-layout.'
      printf '[input.keyboard]\nlayout = %s\n\n' "$(json_str "$XKB_LAYOUT_OVERRIDE")"
    fi
  } > "$INTEGRATION_CONFIG"
  # Раскладку НЕ форсируем: без layout/variant/options/model Umbriel берёт
  # keymap из systemd-localed (localectl set-x11-keymap) — поведение из docs.
  if (( MAIN_KEYBINDS )); then
    toml set "$INTEGRATION_CONFIG" 'keybinds."Mod+Shift+C"' '"spawn noctalia msg panel-toggle control-center"' || warn 'keybind control-center не добавлен.'
    pkg_installed nautilus && toml set "$INTEGRATION_CONFIG" 'keybinds."Mod+E"' '"spawn nautilus"'
    pkg_installed firefox-esr && toml set "$INTEGRATION_CONFIG" 'keybinds."Mod+B"' '"spawn firefox-esr"'
    if [[ $XKB_LAYOUTS_NOW == *,* ]]; then
      toml set "$INTEGRATION_CONFIG" 'keybinds."Mod+Shift+K"' '"keyboard-layout-next"' || true
    fi
  else
    warn 'В основном config.toml нет таблицы [keybinds]: не добавляю урезанную таблицу в include (она заменила бы встроенный набор binds).'
  fi
  toml validate "$INTEGRATION_CONFIG" || die 'Сгенерированный integration-файл невалиден.'
fi
CUR_FILES=$(toml get "$USER_CONFIG" include.optional.files 2>/dev/null || echo '[]')
if ! FILES_JSON=$(python3 - "$CUR_FILES" "$(basename "$INTEGRATION_CONFIG")" <<'PY_FILES'
import json,sys
try: f=json.loads(sys.argv[1])
except Exception: f=[]
f=[x for x in f if isinstance(x,str)]
if sys.argv[2] not in f: f.append(sys.argv[2])
print(json.dumps(f,ensure_ascii=False))
PY_FILES
); then
  die 'Не удалось обновить include.optional.files (python3 error).'
fi
toml set "$USER_CONFIG" include.optional.files "$FILES_JSON" || die 'Не удалось зарегистрировать include (файл не повреждён).'
chown "$TARGET_USER:$TARGET_GROUP" "$USER_CONFIG" "$INTEGRATION_CONFIG"
chmod 0644 "$USER_CONFIG" "$INTEGRATION_CONFIG"
info "Include зарегистрирован: $INTEGRATION_CONFIG"

# ---------------- встроенный polkit-агент Noctalia ----------------------------
install -d -m 0755 /etc/xdg/noctalia
if [[ ! -e $NOCTALIA_DISTRO_DEFAULT ]]; then
  cat > "$NOCTALIA_DISTRO_DEFAULT" <<'EOF_POLKIT'
# Managed by Umbriel + Noctalia installer: системные значения по умолчанию.
# Пользовательские ~/.config/noctalia/*.toml и settings.toml имеют приоритет.
[shell]
polkit_agent = true
EOF_POLKIT
  chmod 0644 "$NOCTALIA_DISTRO_DEFAULT"
else
  toml set "$NOCTALIA_DISTRO_DEFAULT" shell.polkit_agent true || warn 'polkit_agent не выставлен.'
fi
info 'Включён встроенный polkit-агент Noctalia ([shell] polkit_agent = true).'

# ------------------- Secret Service: снять маскировки от v10 -----------------
if (( REPAIR_KEYRING )); then
  for unit in gnome-keyring-daemon.service gnome-keyring-daemon.socket; do
    mask="$TARGET_HOME/.config/systemd/user/$unit"
    if [[ -L $mask && $(readlink "$mask") == /dev/null ]]; then
      backup_path "$mask" "home/keyring-mask/$unit"; rm -f -- "$mask"
      info "Снята маскировка $unit (нужен для Secret Service Noctalia v5)."
    fi
  done
  for f in "$TARGET_HOME/.config/autostart"/gnome-keyring-*.desktop; do
    [[ -f $f ]] || continue
    if grep -q '^Hidden=true' "$f" && grep -q 'Disabled GNOME Keyring Autostart' "$f"; then
      backup_path "$f" "home/autostart/$(basename "$f")"; rm -f -- "$f"
      info "Снят autostart-override $(basename "$f")."
    fi
  done
fi

# ---------------------------------- kitty -----------------------------------
KITTY_DIR="$TARGET_HOME/.config/kitty"; KITTY_CONF="$KITTY_DIR/kitty.conf"
KITTY_EXTRA="$KITTY_DIR/umbriel-noctalia.conf"
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$KITTY_DIR"
{
  printf '# Managed by %s %s.\n' "$PROGRAM" "$SCRIPT_VERSION"
  pkg_installed fonts-jetbrains-mono && printf 'font_family JetBrains Mono\n'
  cat <<'EOF_KITTY'
font_size 12.0
background_opacity 0.90
window_padding_width 10
confirm_os_window_close 0
map ctrl+shift+c copy_to_clipboard
map ctrl+shift+v paste_from_clipboard
EOF_KITTY
} > "$KITTY_EXTRA"
if [[ ! -e $KITTY_CONF ]]; then printf 'include %s\n' "$KITTY_EXTRA" > "$KITTY_CONF"
elif ! grep -Fq 'umbriel-noctalia.conf' "$KITTY_CONF"; then
  printf '\n# >>> Umbriel + Noctalia managed include >>>\ninclude %s\n# <<< Umbriel + Noctalia managed include <<<\n' "$KITTY_EXTRA" >> "$KITTY_CONF"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$KITTY_DIR"; chmod 0644 "$KITTY_EXTRA" "$KITTY_CONF"

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" LANG="$CURRENT_LOCALE" LC_ALL="$CURRENT_LOCALE" \
    XDG_CONFIG_HOME="$TARGET_HOME/.config" xdg-user-dirs-update || warn 'xdg-user-dirs-update не удался.'
fi

# ------------------------------ валидация -----------------------------------
RUN_ENV=(HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config")
if [[ -S "/run/user/$TARGET_UID/bus" ]]; then
  RUN_ENV+=(XDG_RUNTIME_DIR="/run/user/$TARGET_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus")
fi
VJSON="$TMP_DIR/validate.json"; VERR="$TMP_DIR/validate.err"; rc=0
# Сначала пробуем с --json; если флаг не поддерживается — повторяем без него.
if ! runuser -u "$TARGET_USER" -- env "${RUN_ENV[@]}" umbriel config validate --json >"$VJSON" 2>"$VERR"; then
  rc=$?
  if ! runuser -u "$TARGET_USER" -- env "${RUN_ENV[@]}" umbriel config validate >"$VERR" 2>&1; then
    rc=$?
  else
    rc=0
  fi
else
  rc=0
fi
UMBRIEL_VALID=0
if [[ -s "$VJSON" ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("valid") else 1)' "$VJSON" 2>/dev/null; then
  UMBRIEL_VALID=1
elif (( rc == 0 )); then
  UMBRIEL_VALID=1
fi
if (( UMBRIEL_VALID )); then info 'umbriel config validate: OK'
else
  warn 'umbriel config validate сообщил о проблемах:'
  python3 - "$VJSON" <<'PY_DIAG' || cat "$VERR" >&2
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
for x in d.get('diagnostics',[]):
    print('  %s: %s (%s:%s)' % (x.get('severity'), x.get('message'), x.get('file'), x.get('line')), file=sys.stderr)
PY_DIAG
fi

# --------------------------------- greetd -----------------------------------
greetd_effective_config(){
  local line cfg='' d f
  if command -v systemctl >/dev/null 2>&1; then
    line=$(systemctl cat greetd.service 2>/dev/null | grep -E '^[[:space:]]*ExecStart=.+' | tail -n1 || true)
    [[ -z $line ]] || cfg=$(sed -nE 's/.*(-c|--config)[= ]+([^[:space:]]+).*/\2/p' <<<"$line" | tail -n1)
  fi
  if [[ -z $cfg ]]; then
    for d in /etc/systemd/system/greetd.service.d /usr/lib/systemd/system/greetd.service.d /lib/systemd/system/greetd.service.d; do
      [[ -d $d ]] || continue
      for f in "$d"/*.conf; do
        [[ -r $f ]] || continue
        cfg=$(sed -nE 's/.*(-c|--config)[= ]+([^[:space:]]+).*/\2/p' "$f" | tail -n1)
        [[ -z $cfg ]] || break
      done
      [[ -z $cfg ]] || break
    done
  fi
  cfg=${cfg%\"}; cfg=${cfg#\"}; cfg=${cfg%\'}; cfg=${cfg#\'}
  printf '%s\n' "${cfg:-/etc/greetd/config.toml}"
}
greeter_defaults(){
  local state=/var/lib/noctalia-greeter cfg="$state/greeter.toml" f ex nm name=''
  [[ -d $state ]] || return 0
  for f in /usr/share/wayland-sessions/*.desktop /usr/local/share/wayland-sessions/*.desktop; do
    [[ -r $f ]] || continue
    ex=$(sed -n 's/^Exec=//p' "$f" | head -n1)
    [[ $ex == *umbriel* ]] || continue
    nm=$(sed -n 's/^Name=//p' "$f" | head -n1)
    [[ -z $nm ]] || { name=$nm; break; }
  done
  if [[ -n $name ]]; then
    toml set "$cfg" session.default "$(json_str "$name")" && info "Greeter: сеанс по умолчанию — $name" || warn 'session.default не задан.'
  fi
  if (( GREETER_DEFAULT_USER )); then
    toml set "$cfg" user.default "$(json_str "$TARGET_USER")" || warn 'user.default не задан.'
  fi
  if [[ -n $XKB_LAYOUTS_NOW && $XKB_LAYOUTS_NOW =~ ^[A-Za-z0-9_,]+$ ]]; then
    toml set "$cfg" keyboard.layout "$(json_str "$XKB_LAYOUTS_NOW")" || warn 'keyboard.layout greeter не задан.'
  fi
  [[ -f $cfg ]] || return 0
  chown "$GREETER_ACCOUNT:$(id -gn "$GREETER_ACCOUNT" 2>/dev/null || echo "$GREETER_ACCOUNT")" "$cfg" 2>/dev/null || true
  chmod 0644 "$cfg" 2>/dev/null || true
  return 0
}
GREETER_ENABLED=0; GREETER_ACCOUNT=greeter
if (( WITH_GREETER )); then
  section 'НАСТРОЙКА NOCTALIA GREETER'
  GREETER_SESSION=$(command -v noctalia-greeter-session 2>/dev/null || true)
  if [[ -z $GREETER_SESSION ]]; then warn 'noctalia-greeter-session не найден: greetd не включаю.'
  elif ! pkg_installed greetd; then warn 'greetd не установлен: greetd не включаю.'
  elif (( ! UMBRIEL_VALID )) && (( ! FORCE_GREETER )); then warn 'Конфиг Umbriel не прошёл валидацию: greetd не включаю (--force-greeter).'
  else
    GREETD_CONFIG=$(greetd_effective_config)
    info "Конфигурация greetd: $GREETD_CONFIG"
    backup_path "$GREETD_CONFIG" "etc/greetd/$(basename "$GREETD_CONFIG").pre-noctalia"
    CUR_CMD=$(toml get "$GREETD_CONFIG" default_session.command 2>/dev/null || echo '""')
    if [[ $CUR_CMD != *noctalia-greeter-session* ]]; then
      toml set "$GREETD_CONFIG" default_session.command "$(json_str "$GREETER_SESSION")" \
        || die "Не удалось задать default_session.command в $GREETD_CONFIG."
      info 'default_session.command → noctalia-greeter-session'
    fi
    if ! toml get "$GREETD_CONFIG" default_session.user >/dev/null 2>&1; then
      if getent passwd greeter >/dev/null 2>&1; then
        toml set "$GREETD_CONFIG" default_session.user '"greeter"' || warn 'default_session.user не задан.'
      else warn 'Нет аккаунта greeter и ключа user — проверьте конфиг greetd.'; fi
    fi
    toml get "$GREETD_CONFIG" default_session.command | grep -q noctalia-greeter-session || die 'Проверка greetd не пройдена.'
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
      systemd-tmpfiles --create noctalia-greeter.conf || warn 'tmpfiles noctalia-greeter не применены.'
    fi
    if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
      GREETER_ACCOUNT=$(noctalia-greeter-apply-appearance --print-greeter-user 2>/dev/null || true)
      if ! getent passwd "$GREETER_ACCOUNT" >/dev/null 2>&1; then
        for cand in _greeter greeter noctalia-greeter; do
          if getent passwd "$cand" >/dev/null 2>&1; then GREETER_ACCOUNT=$cand; break; fi
        done
      fi
      getent passwd "$GREETER_ACCOUNT" >/dev/null 2>&1 || {
        GREETER_ACCOUNT=greeter
        warn "greeter-аккаунт не найден, использую 'greeter' (может быть неверно)."
      }
      GREETER_USER="$GREETER_ACCOUNT" noctalia-greeter-apply-appearance --setup-system \
        || warn 'Не удалось инициализировать состояние greeter (--setup-system).'
      greeter_defaults
    else
      warn 'noctalia-greeter-apply-appearance не найден — состояние greeter не инициализировано.'
      if (( GREETER_DEFAULT_USER )); then
        warn '--greeter-default-user: требуется noctalia-greeter-apply-appearance.'
      fi
    fi
    if [[ -d /run/systemd/system ]]; then
      if [[ -n $CURRENT_DM_UNIT && $CURRENT_DM_UNIT != greetd.service ]] && (( REPLACE_DM )); then
        systemctl disable "$CURRENT_DM_UNIT" || warn "Не отключён $CURRENT_DM_UNIT."
      fi
      systemctl enable greetd.service || die 'greetd.service не включён.'
      if [[ $(systemctl get-default 2>/dev/null || true) == multi-user.target ]]; then
        warn 'Переключаю default target multi-user → graphical (нужно для greetd).'
        systemctl set-default graphical.target || die 'graphical.target не установлен.'
      fi
      GREETER_ENABLED=1; info 'greetd включён (запуск после перезагрузки).'
    else warn 'systemd не запущен: greetd не включён.'; fi
  fi
fi

# --------------------------------- службы -----------------------------------
if [[ -d /run/systemd/system ]]; then
  (( ENABLE_NM )) && { systemctl enable NetworkManager.service >/dev/null 2>&1 || warn 'NetworkManager не включён.'; }
  systemctl enable power-profiles-daemon.service >/dev/null 2>&1 || true
  if (( ENABLE_BLUETOOTH )) || (( HAS_BT )); then
    systemctl enable bluetooth.service >/dev/null 2>&1 || warn 'bluetooth.service не включён.'
    if [[ -d /sys/class/bluetooth ]] && ! find /sys/class/bluetooth -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      D=/etc/systemd/system/bluetooth.service.d
      backup_path "$D/90-umbriel-noctalia.conf" 'etc/bluez-dropin.pre'
      install -d -m 0755 "$D"
      printf '[Unit]\nConditionPathIsDirectory=\n' > "$D/90-umbriel-noctalia.conf"
      systemctl daemon-reload || true
      systemctl restart bluetooth.service || warn 'bluetooth.service не запустился.'
      info 'BlueZ: снято условие пропуска при пустом /sys/class/bluetooth (VM без адаптера).'
    fi
  fi
fi

# --------------------------------- итог -------------------------------------
section "УСТАНОВКА ЗАВЕРШЕНА (v$SCRIPT_VERSION)"
dpkg-query -W -f='  ${Package} ${Version} ${db:Status-Status}\n' \
  umbriel noctalia noctalia-greeter greetd xdg-desktop-portal-umbriel fonts-noctalia-tabler kitty 2>/dev/null || true
cat <<REPORT

Пользователь:     $TARGET_USER ($TARGET_HOME)
Локаль:           $CURRENT_LOCALE
Target-release:   ${TARGET_RELEASE:-none}
Config Umbriel:   $USER_CONFIG
Integration:      $INTEGRATION_CONFIG
Polkit (distro):  $NOCTALIA_DISTRO_DEFAULT  ([shell] polkit_agent = true)
Umbriel validate: $( ((UMBRIEL_VALID)) && echo OK || echo FAILED)
Greeter включён:  $( ((GREETER_ENABLED)) && echo yes || echo no)
Backup:           $BACKUP_DIR
Log:              $LOG_FILE

Клавиши (штатный пример Umbriel + добавленное):
  Super+Enter — kitty, Super — лаунчер Noctalia, Super+Q — закрыть окно
  Super+Shift+C — Control Center; Super+E / Super+B — если поставлены nautilus/firefox-esr

Проверьте перед перезагрузкой:
  umbriel config validate
  systemctl cat greetd.service
  cat $(greetd_effective_config)
  ls -l /usr/share/wayland-sessions/
  systemctl is-enabled greetd.service; systemctl get-default

Синхронизация оформления с экраном входа (по желанию):
  Settings → Security → Noctalia Greeter → Sync Now
  беспарольный вариант — только осознанный выбор администратора:
  sudo noctalia-greeter passwordless-sync enable $TARGET_USER

Перезагрузку скрипт НЕ выполняет. Откат настроек — из $BACKUP_DIR.
REPORT
((${#MISSING_PKGS[@]})) && printf '\nНе установлено (отсутствовало): %s\n' "${MISSING_PKGS[*]}"
(( UMBRIEL_VALID )) || printf '\nВНИМАНИЕ: конфиг Umbriel не прошёл валидацию — исправьте до перезагрузки.\n'
(( GREETER_ENABLED || ! WITH_GREETER )) || printf '\nВНИМАНИЕ: greetd не включён — вход останется консольным.\n'