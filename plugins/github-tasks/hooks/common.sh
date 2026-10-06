#!/usr/bin/env bash
# Общее для хуков github-tasks. Подключается через `. common.sh`.
#
# Хуки действуют только в проекте, где есть .claude/github-tasks.json и в нём не
# выключены хуки ("hooks": false). В остальных проектах пользователя плагин молчит.

# Поле из JSON на stdin хука: `hk_field tool_input.command`. Читает python3 или node.
hk_field() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
v = json.loads(sys.stdin.read() or "{}")
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1"
  elif command -v node >/dev/null 2>&1; then
    node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  let v = JSON.parse(s || "{}");
  for (const k of process.argv[1].split(".")) v = (v && typeof v === "object") ? v[k] : undefined;
  console.log(v === undefined || v === null ? "" : String(v));
});' "$1"
  else
    cat >/dev/null; echo ""
  fi
}

# Корень основной копии репозитория для каталога $1 (или пусто, если не репозиторий).
hk_root() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  dirname "$common"
}

# Включён ли процесс в репозитории с корнем $1: есть файл настроек и hooks не false.
hk_enabled() {
  local cfg="$1/.claude/github-tasks.json"
  [ -f "$cfg" ] || return 1
  ! grep -qE '"hooks"[[:space:]]*:[[:space:]]*false' "$cfg"
}

# base_branch из файла настроек (пусто, если не задана).
hk_base_branch() {
  sed -nE 's/.*"base_branch"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1/.claude/github-tasks.json" | head -1
}

# Папки процесса — поле paths из файла настроек, по строке на папку, относительно корня
# репозитория, без «./» в начале и «/» в конце. Пустой вывод — процесс на весь
# репозиторий: поля нет, список пуст, в нём есть «.» или «..», нестроковый элемент, файл
# не читается или нет ни python3, ни node. При сомнении — весь репозиторий: это строже.
hk_paths() {
  local cfg="$1/.claude/github-tasks.json"
  [ -f "$cfg" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("paths")
except Exception:
    sys.exit(0)
if isinstance(v, str): v = [v]
if not isinstance(v, list): sys.exit(0)
out = []
for p in v:
    if not isinstance(p, str) or "\n" in p: sys.exit(0)
    p = p.strip()
    while p.startswith("./") or p.startswith("/"): p = p[1:] if p.startswith("/") else p[2:]
    p = p.rstrip("/")
    if p in ("", ".") or ".." in p.split("/"): sys.exit(0)
    out.append(p)
if out: print("\n".join(out))' "$cfg" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e '
let v;
try { v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).paths; } catch (e) { process.exit(0); }
if (typeof v === "string") v = [v];
if (!Array.isArray(v)) process.exit(0);
const out = [];
for (let p of v) {
  if (typeof p !== "string" || p.includes("\n")) process.exit(0);
  p = p.trim();
  while (p.startsWith("./") || p.startsWith("/")) p = p.startsWith("/") ? p.slice(1) : p.slice(2);
  p = p.replace(/\/+$/, "");
  if (p === "" || p === "." || p.split("/").includes("..")) process.exit(0);
  out.push(p);
}
if (out.length) console.log(out.join("\n"));' "$cfg" 2>/dev/null
  fi
}

# Основная ветка репозитория по origin/HEAD, без обращения к сети.
hk_default_branch() {
  local ref
  ref=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  [ -n "$ref" ] && echo "${ref#origin/}" || echo main
}

# ---------------------------------------------------------------------------------------
# Разбор путей и переменных команды — общий для guard-git.sh и guard-readonly.sh.
# Функции опираются на переменные вызывающего хука: curdir (текущий каталог по ходу
# команды), prevdir (прежний — для cd - и $OLDPWD), subval (значение последней
# подстановки $(…)), VARN/VARV (переменные, присвоенные в этой команде).
# Ограничения разбора (форма записи — нарочно необычная):
# - всё под временной папкой из $(mktemp -d) считается вне репозиториев, подпуть и
#   значение флага mkdir (mkdir -m 755 x) — созданными каталогами; удачность git clone
#   не проверяется; local вне функции считается присваиванием;
# - значение подстановки одно на простую команду — последней; в форме с двумя
#   подстановками в одной команде (tee "$(pwd)/x" < "$(mktemp)") первая раскроется
#   значением второй;
# - присваивание в ветке условия или внутри ( … ) считается выполненным; unset не
#   учитывается; cd в теле функции считается выполненным при объявлении;
# - popd при пустом стеке возвращает к каталогу сессии (bash в этом случае остаётся на
#   месте и печатает ошибку).
TMPBASE=${TMPDIR:-/tmp}; TMPBASE=${TMPBASE%/}
VARN=(); VARV=(); subval="?"; curdir=""; prevdir=""; MKDIRS=(); CLONED=()

# Можно ли считать, что cd в каталог $1 (уже нормализованный) удастся: каталог есть, это
# временная папка из $(mktemp -d) или его создаёт mkdir или git clone раньше в этой же
# команде. Иначе
# cd в bash не сработает и команда продолжится в прежнем каталоге.
dir_reachable() {
  local m tb
  [ -d "$1" ] && return 0
  tb=$(norm "$TMPBASE" /)
  case "$1" in "$TMPBASE"/mktemp|"$TMPBASE"/mktemp/*|"$tb"/mktemp|"$tb"/mktemp/*) return 0 ;; esac
  for m in ${MKDIRS[@]+"${MKDIRS[@]}"} ${CLONED[@]+"${CLONED[@]}"}; do case "$1/" in "$m"/*) return 0 ;; esac; done
  return 1
}

# Каталог, по которому определять репозиторий и ветку для ещё не существующего $1:
# ближайший существующий родитель (подкаталог из mkdir остаётся частью репозитория).
# Пусто — каталог вне репозиториев: цель git clone или временная папка из mktemp -d.
real_dir() {
  local d=$1 m tb
  [ -d "$d" ] && { echo "$d"; return; }
  tb=$(norm "$TMPBASE" /)
  case "$d" in "$TMPBASE"/mktemp|"$TMPBASE"/mktemp/*|"$tb"/mktemp|"$tb"/mktemp/*) return ;; esac
  for m in ${CLONED[@]+"${CLONED[@]}"}; do case "$d/" in "$m"/*) return ;; esac; done
  while [ "$d" != / ] && [ -n "$d" ] && [ ! -d "$d" ]; do d=${d%/*}; done
  echo "${d:-/}"
}

# Значение переменной, присвоенной в этой команде, или известной ($TMPDIR, $HOME, $PWD, $OLDPWD).
var_get() {
  local k
  for ((k = ${#VARN[@]} - 1; k >= 0; k--)); do [ "${VARN[$k]}" = "$1" ] && { echo "${VARV[$k]}"; return 0; }; done
  case "$1" in
    TMPDIR) echo "$TMPBASE"; return 0 ;;
    HOME) echo "$HOME"; return 0 ;;
    PWD) echo "$curdir"; return 0 ;;
    OLDPWD) echo "$prevdir"; return 0 ;;
  esac
  return 1
}
# Значение с переменной в начале ($VAR/…, ${VAR}…, ~) — раскрыть; неизвестная → «?».
expand_value() {
  local p=$1 name rest v
  case "$p" in
    $'\004'*)   # слово начинается с подстановки $(…): её значение + хвост
      [ "$subval" = "?" ] && { echo "?"; return; }
      echo "$subval${p#$'\004'}" ;;
    '$'*)
      name=$(printf '%s' "$p" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/')
      rest=$(printf '%s' "$p" | sed -E 's/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?//')
      v=$(var_get "$name") || { echo "?"; return; }
      [ "$v" = "?" ] && { echo "?"; return; }
      echo "$v$rest" ;;
    "~"|"~/"*) echo "$HOME${p#\~}" ;;
    *) echo "$p" ;;
  esac
}
# Чему равна подстановка $(команда): mktemp → временная папка, pwd → текущий каталог,
# git rev-parse --show-toplevel → корень репозитория текущего каталога; иное → «?».
subst_value() {  # слова команды
  case "${1##*/} ${2:-}" in
    "mktemp "*) echo "$TMPBASE/mktemp" ;;
    "pwd "*) echo "$curdir" ;;
    "git rev-parse")
      # --show-toplevel даёт корень рабочей копии (в worktree — саму рабочую копию)
      if [ "${3:-}" = --show-toplevel ]; then git -C "$curdir" rev-parse --show-toplevel 2>/dev/null || echo "?"; return; fi
      echo "?" ;;
    "realpath "*|"readlink "*) [ -n "${2:-}" ] && norm "$2" "$curdir" || echo "?" ;;
    *) echo "?" ;;
  esac
}

# Путь без «.» и «..», с раскрытием ссылок (каталогов и самого файла; на macOS /tmp — это
# /private/tmp), переменных из этой команды, $TMPDIR, $HOME и ~, с настоящим регистром
# существующих каталогов. Неизвестная переменная в начале пути — печатает «?» (путь
# неизвестен).
norm() {
  local p=$1 base=$2 out="" part head tail v name rest n
  p=$(expand_value "$p"); [ "$p" = "?" ] && { echo "?"; return; }
  case "$p" in /*) ;; *) p="$base/$p" ;; esac
  for n in 1 2 3 4 5 6 7 8; do
    out=""
    local IFS=/
    for part in $p; do
      case "$part" in ''|.) ;; ..) out=${out%/*} ;; *) out="$out/$part" ;; esac
    done
    unset IFS
    [ -n "$out" ] || out=/
    head=$out; tail=""
    while [ "$head" != / ] && [ ! -d "$head" ]; do
      tail="/${head##*/}$tail"; head=${head%/*}; [ -n "$head" ] || head=/
    done
    # /bin/pwd -P, а не встроенный pwd: на macOS встроенный отдаёт регистр, как набрали
    # (Tools/VB-Bot), а git и файловая система — настоящий (tools/vb-bot).
    head=$(cd -P "$head" 2>/dev/null && { /bin/pwd -P 2>/dev/null || pwd -P; }) || head=/
    [ "$head" = / ] && head=""
    p="$head$tail"
    # последний элемент — ссылка на файл: идём по ней
    if [ -n "$tail" ] && [ -L "$p" ]; then
      v=$(readlink "$p")
      case "$v" in /*) p=$v ;; *) p="$(dirname "$p")/$v" ;; esac
      continue
    fi
    break
  done
  echo "$p"
}


# Каталог, который создаст git clone: второй позиционный аргумент после URL (флаги со
# значением пропускаются), иначе имя репозитория из URL. Печатает путь как есть.
clone_target() {
  local a npos=0 url="" tgt="" k=0 all=("$@")
  while [ "$k" -lt "${#all[@]}" ]; do
    a=${all[$k]}
    case "$a" in
      -b|--branch|-o|--origin|--depth|--reference|--reference-if-able|-c|--config|--template|--separate-git-dir|--filter|-j|--jobs|--shallow-since|--shallow-exclude|-u|--upload-pack|--server-option) k=$((k+2)); continue ;;
      -*) ;;
      *) npos=$((npos+1)); [ "$npos" = 1 ] && url=$a; [ "$npos" = 2 ] && tgt=$a ;;
    esac
    k=$((k+1))
  done
  if [ -z "$tgt" ] && [ -n "$url" ]; then tgt=${url%/}; tgt=${tgt##*/}; tgt=${tgt##*:}; tgt=${tgt%.git}; fi
  echo "$tgt"
}
