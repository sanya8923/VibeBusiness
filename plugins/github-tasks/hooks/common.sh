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
# Ограничение: значение подстановки одно на простую команду — последней; в редкой форме
# с двумя подстановками в одной команде (tee "$(pwd)/x" < "$(mktemp)") первая раскроется
# значением второй.
TMPBASE=${TMPDIR:-/tmp}; TMPBASE=${TMPBASE%/}
VARN=(); VARV=(); subval="?"; curdir=""; prevdir=""

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
    "git rev-parse") [ "${3:-}" = --show-toplevel ] && { hk_root "$curdir"; return; }; echo "?" ;;
    "realpath "*|"readlink "*) [ -n "${2:-}" ] && norm "$2" "$curdir" || echo "?" ;;
    *) echo "?" ;;
  esac
}

# Путь без «.» и «..», с раскрытием ссылок (каталогов и самого файла; на macOS /tmp — это
# /private/tmp), переменных из этой команды, $TMPDIR, $HOME и ~. Неизвестная переменная
# в начале пути — печатает «?» (путь неизвестен).
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
    head=$(cd -P "$head" 2>/dev/null && pwd) || head=/
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

