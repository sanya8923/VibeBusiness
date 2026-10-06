#!/usr/bin/env bash
# PreToolUse-хук: приёмщик и разведчик плагина не меняют проект и GitHub.
#
# Агенту из плагина нельзя задать собственные хуки и нельзя ограничить Bash отдельными
# командами, а Bash приёмщику нужен — запускать проверки. Поэтому ограничение здесь: хук
# видит тип субагента (agent_type) и для github-tasks:reviewer и github-tasks:scout
# работает по СПИСКУ РАЗРЕШЁННОГО, а не по списку запрещённого — запретов для Bash не
# перечислить (perl -pi, ruby -pi, dd, find -delete, python -c …).
#
#   - Edit, Write, NotebookEdit, MultiEdit — запрещены всегда.
#   - Внутри проекта сессии (рабочий каталог команды — в проекте) разрешены только
#     читающие команды: cat, grep, ls, find без -exec/-delete, diff и т. п.; git — только
#     читающие подкоманды и fetch; gh — только просмотр, списки и gh api на чтение.
#   - Во временной папке вне проекта (/tmp, $TMPDIR) можно всё: там приёмщик клонирует
#     ветку PR и запускает проверки. Но и оттуда нельзя писать в файлы проекта: аргументы
#     и цели перенаправлений, указывающие внутрь проекта, проверяются.
#   - Запись в GitHub — только одна: приёмщику — комментарий в PR (так публикуется
#     вердикт), без --edit-last/--delete-last. Разведчику — никакой.
#
# Известные ограничения: код внутри интерпретатора, запущенного во временной папке
# (python -c "open('/путь/проекта/…','w')"), хук не разбирает; eval и bash -c внутри
# проекта запрещены целиком, во временной папке внутрь не разбираются.
set -uo pipefail
set -f
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

INPUT=$(cat)
AGENT=$(printf '%s' "$INPUT" | hk_field agent_type)
case "$AGENT" in
  github-tasks:reviewer|github-tasks:scout) ;;
  *) exit 0 ;;
esac
TOOL=$(printf '%s' "$INPUT" | hk_field tool_name)
CWD=$(printf '%s' "$INPUT" | hk_field cwd)
[ -n "$CWD" ] || CWD=$PWD
WHO=${AGENT#github-tasks:}

deny() {
  echo "github-tasks: $WHO работает только на чтение — $1" >&2
  echo "Проверки запускай в копии во временной папке: git clone -b <ветка PR> <репозиторий> \"\$TMPDIR/review\". Найденный дефект опиши в вердикте — исправляет исполнитель." >&2
  exit 2
}

case "$TOOL" in
  Edit|Write|NotebookEdit|MultiEdit) deny "инструмент $TOOL правит файлы." ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | hk_field tool_input.command)
[ -n "$CMD" ] || exit 0

# Путь без «.» и «..», с раскрытием ссылок у существующей части (на macOS /tmp — это
# /private/tmp). $TMPDIR, $HOME и ~ раскрываются.
norm() {
  local p=$1 base=$2 out="" part head tail
  case "$p" in
    '$TMPDIR'|'${TMPDIR}') p=${TMPDIR:-/tmp} ;;
    '$TMPDIR/'*) p="${TMPDIR:-/tmp}/${p#\$TMPDIR/}" ;;
    '${TMPDIR}/'*) p="${TMPDIR:-/tmp}/${p#\$\{TMPDIR\}/}" ;;
    '$HOME'|'${HOME}'|"~") p=$HOME ;;
    '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) ;; *) p="$base/$p" ;; esac
  local IFS=/
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  [ -n "$out" ] || out=/
  # раскрыть ссылки в самой длинной существующей части пути
  head=$out; tail=""
  while [ "$head" != / ] && [ ! -d "$head" ]; do
    tail="/${head##*/}$tail"; head=${head%/*}; [ -n "$head" ] || head=/
  done
  head=$(cd -P "$head" 2>/dev/null && pwd) || head=/
  [ "$head" = / ] && head=""
  echo "$head$tail"
}

PROOT_RAW=$(hk_root "$CWD")
PROOT=""
[ -n "$PROOT_RAW" ] && PROOT=$(norm "$PROOT_RAW" /)

in_project() {  # путь $1 от каталога $2 — внутри проекта сессии
  [ -n "$PROOT" ] || return 1
  local p
  p=$(norm "$1" "$2")
  case "$p/" in "$PROOT"/*) return 0 ;; esac
  return 1
}

# Флаги обёрток, которые берут значение следующим словом.
wrapper_flag_value() {  # обёртка флаг
  case "$1:$2" in
    sudo:-u|sudo:-g|sudo:-C|sudo:-D|sudo:-h|sudo:-p|sudo:-r|sudo:-t|sudo:-U|sudo:--user|sudo:--group) return 0 ;;
    timeout:-s|timeout:-k|timeout:--signal|timeout:--kill-after) return 0 ;;
    gtimeout:-s|gtimeout:-k|gtimeout:--signal|gtimeout:--kill-after) return 0 ;;
    nice:-n|nice:--adjustment) return 0 ;;
    env:-u|env:-C|env:-S|env:--unset|env:--chdir|env:--split-string) return 0 ;;
    xargs:-I|xargs:-n|xargs:-P|xargs:-L|xargs:-d|xargs:-E|xargs:-s|xargs:-a) return 0 ;;
    stdbuf:-i|stdbuf:-o|stdbuf:-e) return 0 ;;
    ionice:-c|ionice:-n|ionice:-p) return 0 ;;
    time:-o|time:-f) return 0 ;;
  esac
  return 1
}

# Читающие команды: внутри проекта разрешены с любыми аргументами.
READERS=" cat less more head tail wc ls stat file grep egrep fgrep rg ag diff cmp comm sort uniq cut tr jq yq echo printf pwd which type true false test [ date basename dirname realpath readlink tree du df md5 md5sum shasum sha1sum sha256sum cksum xxd hexdump od strings column nl fold expand sleep uname id whoami hostname ps nproc locale tput "

git_read_ok() {  # подкоманда и аргументы git — только чтение?
  local sub=$1; shift
  case " $* " in *" --output"*|*" -o "*) case "$sub" in diff|log|show|format-patch) return 1 ;; esac ;; esac
  case "$sub" in
    status|log|diff|show|blame|grep|ls-files|ls-tree|ls-remote|rev-parse|rev-list|cat-file|describe|shortlog|merge-base|name-rev|for-each-ref|show-ref|count-objects|check-ignore|var|help|version|fetch) return 0 ;;
    reflog) case "${1:-show}" in show|-*) return 0 ;; esac; return 1 ;;
    stash) [ "${1:-}" = list ] || [ "${1:-}" = show ]; return ;;
    worktree) [ "${1:-}" = list ]; return ;;
    config) case " $* " in *" --get"*|*" -l "*|*" --list "*) return 0 ;; esac; return 1 ;;
    branch|tag|remote)
      local a
      for a in "$@"; do
        case "$a" in
          -l|--list|-a|--all|-r|--remotes|-v|-vv|--verbose|--show-current|--contains|--merged|--no-merged|--sort=*|--format=*|-n*) ;;
          show|get-url) [ "$sub" = remote ] || return 1 ;;
          -*) return 1 ;;
          *) [ "$sub" = remote ] || return 1 ;;   # имя без флага списка — создание ветки или тега
        esac
      done
      return 0 ;;
  esac
  return 1
}

gh_check() {  # аргументы gh после обёрток
  local a sub sub2 method="" fields=0 k=0 n=$#
  local all=("$@") pos=()
  # подкоманды — без глобальных флагов (-R/--repo X)
  while [ "$k" -lt "$n" ]; do
    a=${all[$k]}
    case "$a" in
      -R|--repo|--hostname) k=$((k+2)); continue ;;
      -R?*|--repo=*) ;;
      *) pos+=("$a") ;;
    esac
    k=$((k+1))
  done
  sub=${pos[0]:-}; sub2=${pos[1]:-}
  case "$sub" in
    api)
      for a in ${pos[@]+"${pos[@]}"}; do
        case "$a" in
          -X|--method) method=next ;;
          -X?*) method=${a#-X} ;;
          --method=*) method=${a#--method=} ;;
          -f*|-F*|--field*|--raw-field*|--input*) fields=1 ;;
          *) [ "$method" = next ] && method=$a ;;
        esac
      done
      method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
      if [ -n "$method" ] && [ "$method" != GET ]; then deny "gh api с методом $method меняет GitHub."; fi
      if [ "$fields" = 1 ] && [ "$method" != GET ]; then deny "gh api с полями без -X GET — это запись в GitHub."; fi
      return 0 ;;
    auth) [ "$sub2" = status ] && return 0; deny "gh auth $sub2 недоступен приёмщику и разведчику." ;;
    search|version|help|status) return 0 ;;
  esac
  case "$sub2" in
    view|list|diff|checks|status|watch) return 0 ;;
  esac
  if [ "$WHO" = reviewer ] && [ "$sub $sub2" = "pr comment" ]; then
    case " $* " in *" --edit-last "*|*" --delete-last "*) deny "gh pr comment с правкой или удалением прошлого комментария." ;; esac
    return 0
  fi
  deny "gh $sub $sub2 меняет GitHub."
}

curdir=$CWD
while IFS= read -r line; do
  IFS=$'\037' read -r -a raw <<<"$line"
  [ ${#raw[@]} -gt 0 ] || continue

  # Перенаправления (слова с пометкой \002 от tokenize.awk): запись внутрь проекта — нет.
  w=()
  for t in ${raw[@]+"${raw[@]}"}; do
    case "$t" in
      $'\002'*)
        r=${t#$'\002'}
        op=$(printf '%s' "$r" | sed -E 's/^([0-9]*[&]?[<>]+[|&]?).*/\1/')
        tgt=${r#"$op"}
        case "$op" in
          *'>&'|*'<&'|'<'|[0-9]'<'|'<<<') ;;            # дублирование дескриптора и чтение
          *) [ -n "$tgt" ] && in_project "$tgt" "$curdir" && deny "запись в файл проекта $tgt." ;;
        esac ;;
      *) w+=("$t") ;;
    esac
  done
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue

  # Сама команда: служебные слова, присваивания, обёртки с их флагами.
  i=0; wrapper=""
  while [ "$i" -lt "$n" ]; do
    wi=${w[$i]}
    case "${wi##*/}" in
      if|then|else|elif|fi|do|done|while|until|'!') ;;
      time|command|builtin|exec|nohup|nice|sudo|doas|xargs|env|timeout|gtimeout|stdbuf|ionice|caffeinate|chronic|unbuffer|arch) wrapper=${wi##*/} ;;
      -*) if [ -n "$wrapper" ]; then wrapper_flag_value "$wrapper" "$wi" && i=$((i+1)); else break; fi ;;
      *=*) ;;
      *) if [ -n "$wrapper" ] && [[ "$wi" =~ ^[0-9.]+[smhd]?$ ]]; then :; else break; fi ;;
    esac
    i=$((i+1))
  done
  [ "$i" -lt "$n" ] || continue
  cmd=${w[$i]##*/}
  args=("${w[@]:$((i+1))}")
  na=${#args[@]}

  # cd/pushd: следим за каталогом, даже если его ещё нет (mkdir в той же команде)
  if [ "$cmd" = cd ] || [ "$cmd" = pushd ]; then
    curdir=$(norm "${args[0]:-$HOME}" "$curdir"); continue
  fi

  here_project=0; in_project . "$curdir" && here_project=1

  case "$cmd" in
    git)
      gitdir=$curdir; j=0
      while [ "$j" -lt "$na" ] && [[ "${args[$j]}" == -* ]]; do
        case "${args[$j]}" in
          -C) gitdir=$(norm "${args[$((j+1))]:-.}" "$curdir"); j=$((j+2)) ;;
          --git-dir|--work-tree) in_project "${args[$((j+1))]:-.}" "$curdir" && gitdir=$PROOT; j=$((j+2)) ;;
          -c|--namespace) j=$((j+2)) ;;
          --git-dir=*|--work-tree=*) in_project "${args[$j]#*=}" "$curdir" && gitdir=$PROOT; j=$((j+1)) ;;
          *) j=$((j+1)) ;;
        esac
      done
      sub=${args[$j]:-}
      rest=("${args[@]:$((j+1))}")
      if [ "$sub" = clone ]; then
        # цель клона — последний позиционный аргумент; внутрь проекта нельзя
        last=""
        for a in ${rest[@]+"${rest[@]}"}; do case "$a" in -*) ;; *) last=$a ;; esac; done
        [ -z "$last" ] && in_project . "$gitdir" && deny "git clone без каталога назначения — клон окажется в проекте."
        [ -n "$last" ] && in_project "$last" "$gitdir" && deny "git clone внутрь проекта ($last)."
      elif in_project . "$gitdir"; then
        git_read_ok "$sub" ${rest[@]+"${rest[@]}"} || deny "git $sub меняет репозиторий проекта."
      fi
      continue ;;
    gh)
      gh_check ${args[@]+"${args[@]}"}
      [ "${args[0]:-}" = pr ] && [ "${args[1]:-}" = checkout ] && deny "gh pr checkout переключает ветку."
      continue ;;
    find)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls) [ "$here_project" = 1 ] && deny "find $a меняет файлы — внутри проекта только поиск." ;; esac
      done
      [ "$here_project" = 1 ] && continue ;;
    cp|rsync|install|ln)
      # источник может быть в проекте (копия наружу) — проверяем только цель
      tgt=""; last=""; k=0
      while [ "$k" -lt "$na" ]; do
        a=${args[$k]}
        case "$a" in
          -t|--target-directory) tgt=${args[$((k+1))]:-}; k=$((k+2)); continue ;;
          --target-directory=*) tgt=${a#*=} ;;
          -*) ;;
          *) last=$a ;;
        esac
        k=$((k+1))
      done
      [ -n "$tgt" ] || tgt=$last
      [ -n "$tgt" ] && in_project "$tgt" "$curdir" && deny "$cmd в файлы проекта ($tgt)."
      continue ;;
  esac

  # Читающие команды, которые умеют писать в файл флагом или вторым аргументом.
  if true; then
    npos=0; wout=""
    for a in ${args[@]+"${args[@]}"}; do
      case "$a" in -*) ;; *) npos=$((npos+1)) ;; esac
      case "$cmd:$a" in
        sort:-o*|sort:--output*|tree:-o|tree:-o*|file:-C) wout=$a ;;
      esac
    done
    case "$cmd" in uniq|xxd) [ "$npos" -ge 2 ] && wout="второй аргумент — файл вывода" ;; esac
    if [ -n "$wout" ] && [ "$here_project" = 1 ]; then deny "$cmd пишет в файл ($wout)."; fi
  fi
  case "$READERS" in *" $cmd "*) continue ;; esac

  # Файловые команды с путями только вне проекта (mkdir временной папки из проекта) — можно.
  case "$cmd" in
    mkdir|rmdir|rm|touch|mv|chmod)
      bad=0; any=0
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -*) continue ;; esac
        any=1; in_project "$a" "$curdir" && bad=1
      done
      [ "$bad" = 1 ] && deny "$cmd с файлом проекта."
      [ "$any" = 1 ] && continue ;;
  esac

  # Всё остальное (интерпретаторы, сборка, sed, perl, rm, curl …): внутри проекта — нет,
  # во временной папке — да, но без аргументов, указывающих внутрь проекта.
  [ "$here_project" = 1 ] && deny "$cmd внутри проекта — запускай это в копии во временной папке."
  for a in ${args[@]+"${args[@]}"}; do
    case "$a" in
      -*=*) a=${a#*=} ;;
      -*) continue ;;
      *=*) a=${a#*=} ;;
    esac
    case "$a" in */*|.|..) in_project "$a" "$curdir" && deny "$cmd с файлом проекта $a." ;; esac
  done
done < <(printf '%s' "$CMD" | awk -f "$HERE/tokenize.awk")
exit 0
