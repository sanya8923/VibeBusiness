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
#   - git push и send-pack — запрещены в любом каталоге: приёмщик не должен «подправить»
#     проверяемую ветку из своей временной копии.
#   - Внутри проекта сессии (рабочий каталог команды — в проекте) разрешены только
#     читающие команды: cat, grep, ls, find без -exec/-delete, diff и т. п.; git — только
#     читающие подкоманды и fetch в удалённые ветки; gh — просмотр, списки, gh api на чтение.
#   - Во временной папке вне проекта (/tmp, $TMPDIR, mktemp) можно всё: там приёмщик
#     клонирует ветку PR и запускает проверки. Но и оттуда нельзя писать в файлы проекта:
#     аргументы и цели перенаправлений, указывающие внутрь проекта (в том числе через
#     «..» и ссылки), запрещены; ln с источником в проекте — тоже.
#   - Запись в GitHub — только одна: приёмщику — комментарий в PR (так публикуется
#     вердикт), без --edit-last/--delete-last. Разведчику — никакой.
#
# Это защита от случайной правки, а не от злонамеренного обхода. Известные ограничения:
# код внутри интерпретатора, запущенного во временной папке (python -c
# "open('/путь/проекта/…','w')"), и пути, которые пишущая команда во временной папке
# получает через stdin (… | xargs sed -i), хук не видит; шаблоны case (a) …) внутри
# проекта дают ложный запрет — читай файлы инструментом Read.
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
TMPBASE=${TMPDIR:-/tmp}; TMPBASE=${TMPBASE%/}

deny() {
  echo "github-tasks: $WHO работает только на чтение — $1" >&2
  echo "Проверки запускай в копии во временной папке: git clone -b <ветка PR> <репозиторий> \"\$TMPDIR/review\". Файлы читай инструментом Read. Найденный дефект опиши в вердикте — исправляет исполнитель." >&2
  exit 2
}

case "$TOOL" in
  Edit|Write|NotebookEdit|MultiEdit) deny "инструмент $TOOL правит файлы." ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | hk_field tool_input.command)
[ -n "$CMD" ] || exit 0

# Переменные, которым в этой команде присвоено значение (VAR=…, VAR=$(mktemp …)).
VARN=(); VARV=()
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

PROOT_RAW=$(hk_root "$CWD")
PROOT=""
[ -n "$PROOT_RAW" ] && PROOT=$(norm "$PROOT_RAW" /)

in_project() {  # путь $1 от каталога $2 — внутри проекта сессии
  [ -n "$PROOT" ] || return 1
  local p
  p=$(norm "$1" "$2")
  [ "$p" = "?" ] && return 1
  case "$p/" in "$PROOT"/*) return 0 ;; esac
  return 1
}
# Цель записи внутри проекта? Неизвестный путь (переменная извне команды или из
# произвольной подстановки) считается проектом — запись туда не проверить.
write_in_project() {
  local p
  p=$(norm "$1" "$2")
  [ "$p" = "?" ] && return 0
  [ -n "$PROOT" ] || return 1
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

# Читающие команды и встроенные слова оболочки: внутри проекта разрешены.
READERS=" cat less more head tail wc ls stat file grep egrep fgrep rg ag diff cmp comm sort uniq cut tr jq echo printf pwd which type true false test [ [[ date basename dirname realpath readlink tree du df md5 md5sum shasum sha1sum sha256sum cksum xxd hexdump od strings column nl fold expand sleep uname id whoami hostname ps nproc locale tput read export local declare unset set shift return break continue wait printenv env "

git_read_ok() {  # подкоманда и аргументы git — только чтение?
  local sub=$1; shift
  local a listing=0
  case " $* " in *" --output"*) case "$sub" in diff|log|show|format-patch) return 1 ;; esac ;; esac
  case "$sub" in
    status|log|diff|show|blame|grep|ls-files|ls-tree|ls-remote|rev-parse|rev-list|cat-file|describe|shortlog|merge-base|name-rev|for-each-ref|show-ref|count-objects|check-ignore|var|help|version) return 0 ;;
    fetch)
      for a in "$@"; do
        case "$a" in
          --update-head-ok|-u) return 1 ;;
          *:*) case "${a#*:}" in refs/remotes/*) ;; *) return 1 ;; esac ;;   # refspec в локальную ветку
        esac
      done
      return 0 ;;
    reflog) case "${1:-show}" in show|-*) return 0 ;; esac; return 1 ;;
    stash) [ "${1:-}" = list ] || [ "${1:-}" = show ]; return ;;
    worktree) [ "${1:-}" = list ]; return ;;
    config) case " $* " in *" --get"*|*" -l "*|*" --list "*) return 0 ;; esac; return 1 ;;
    remote)
      [ $# = 0 ] && return 0
      case "${1:-}" in -v|--verbose) [ $# = 1 ]; return ;; show|get-url) return 0 ;; esac
      return 1 ;;
    branch|tag)
      [ $# = 0 ] && return 0
      for a in "$@"; do
        case "$a" in
          -l|--list|-a|--all|-r|--remotes|-v|-vv|--verbose|--show-current|--contains|--no-contains|--merged|--no-merged|--points-at|--sort=*|--format=*|--color*|--column*|-n*) listing=1 ;;
          -*) return 1 ;;
        esac
      done
      [ "$listing" = 1 ]; return ;;   # слово без флага списка — создание ветки или тега
  esac
  return 1
}

gh_check() {  # аргументы gh после обёрток
  local a sub sub2 method="" fields=0 k=0 n=$# g mutation=0
  local all=("$@") pos=()
  while [ "$k" -lt "$n" ]; do      # подкоманды — без глобальных флагов (-R/--repo X)
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
          --method=*) method=${a#--method=} ;;
          --field*|--raw-field*|--input*) fields=1 ;;
          --*) ;;
          -?*)
            g=${a#-}
            case "$g" in *X*) method=${g#*X}; [ -n "$method" ] || method=next ;; esac
            case "${g%%X*}" in *f*|*F*) fields=1 ;; esac ;;
          *) if [ "$method" = next ]; then method=$a; fi
             case "$a" in *mutation*|*=@*) mutation=1 ;; esac ;;
        esac
      done
      method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
      if [ "$sub2" = graphql ]; then
        [ "$mutation" = 1 ] && deny "gh api graphql с mutation или запросом из файла (@…) — может менять GitHub."
        return 0   # чтение через GraphQL всегда идёт POST
      fi
      if [ -n "$method" ] && [ "$method" != GET ]; then deny "gh api с методом $method меняет GitHub."; fi
      if [ "$fields" = 1 ] && [ "$method" != GET ]; then deny "gh api с полями без -X GET — это запись в GitHub."; fi
      return 0 ;;
    auth) [ "$sub2" = status ] && return 0; deny "gh auth $sub2 недоступен приёмщику и разведчику." ;;
    search|version|help|status) return 0 ;;
    repo)
      case "$sub2" in
        view|list) return 0 ;;
        clone)
          if [ -n "${pos[3]:-}" ]; then write_in_project "${pos[3]}" "$curdir" && deny "gh repo clone внутрь проекта."
          else [ "$here_project" = 1 ] && deny "gh repo clone без каталога назначения — клон окажется в проекте."; fi
          return 0 ;;
      esac ;;
    pr)
      if [ "$sub2" = checkout ]; then [ "$here_project" = 1 ] && deny "gh pr checkout переключает ветку проекта."; return 0; fi ;;
    run)
      if [ "$sub2" = download ]; then
        local dst="" j=0
        while [ "$j" -lt "${#pos[@]}" ]; do case "${pos[$j]}" in -D|--dir) dst=${pos[$((j+1))]:-} ;; --dir=*) dst=${pos[$j]#*=} ;; esac; j=$((j+1)); done
        if [ -n "$dst" ]; then write_in_project "$dst" "$curdir" && deny "gh run download в проект."
        else [ "$here_project" = 1 ] && deny "gh run download без -D — файлы окажутся в проекте."; fi
        return 0
      fi ;;
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

curdir=$CWD; prevdir=$CWD; last_cmd=""; subval="?"
dstack=(); pstack=()
while IFS= read -r line; do
  # границы подоболочки и подстановки: cd внутри них наружу не действует
  case "$line" in
    $'\003('*) dstack+=("$curdir"); continue ;;
    $'\003)'*)
      if [ ${#dstack[@]} -gt 0 ]; then
        curdir=${dstack[$((${#dstack[@]}-1))]}
        unset "dstack[$((${#dstack[@]}-1))]"; dstack=(${dstack[@]+"${dstack[@]}"})
      fi
      continue ;;
  esac
  IFS=$'\037' read -r -a raw <<<"$line"
  [ ${#raw[@]} -gt 0 ] || continue
  # команда внутри подстановки: запомнить, чему подстановка равна
  if [ ${#dstack[@]} -gt 0 ]; then subval=$(subst_value ${raw[@]+"${raw[@]}"}); fi
  here_project=0; in_project . "$curdir" && here_project=1

  # Перенаправления (слова с пометкой \002 от tokenize.awk): запись внутрь проекта — нет.
  w=()
  for t in ${raw[@]+"${raw[@]}"}; do
    case "$t" in
      $'\002'*)
        r=${t#$'\002'}
        op=$(printf '%s' "$r" | sed -E 's/^([0-9]*[&]?[<>]+[|&]?).*/\1/')
        tgt=${r#"$op"}
        case "$op" in
          '<'|[0-9]'<'|'<<<') ;;                                   # чтение
          *'>&'|*'<&') case "$tgt" in ''|-|[0-9]|[0-9][0-9]) ;;     # дублирование дескриптора
                         *) write_in_project "$tgt" "$curdir" && deny "запись в файл проекта $tgt." ;; esac ;;
          *) [ -n "$tgt" ] && write_in_project "$tgt" "$curdir" && deny "запись в файл проекта $tgt." ;;
        esac ;;
      *) w+=("$t") ;;
    esac
  done
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue

  # Строка из одних присваиваний: запомнить переменные (VAR=$(mktemp …) — временная папка).
  allassign=1
  for t in "${w[@]}"; do case "$t" in [A-Za-z_]*=*) ;; *) allassign=0 ;; esac; done
  if [ "$allassign" = 1 ]; then
    for t in "${w[@]}"; do
      v=${t#*=}
      v=$(expand_value "$v")                       # VAR=$(…)/x, VAR="$TMPDIR/x"
      VARN+=("${t%%=*}"); VARV+=("$v")
    done
    continue
  fi

  # Сама команда: служебные слова, присваивания, обёртки с их флагами.
  i=0; wrapper=""
  while [ "$i" -lt "$n" ]; do
    wi=${w[$i]}
    case "${wi##*/}" in
      if|then|else|elif|fi|do|done|while|until|'!'|'{'|'}'|$'\004') ;;
      for|case|esac|in|select|function) i=$n; break ;;   # заголовок цикла или case — не команда
      time|builtin|exec|nohup|nice|sudo|doas|xargs|timeout|gtimeout|stdbuf|ionice|caffeinate|chronic|unbuffer|arch) wrapper=${wi##*/} ;;
      command)
        case "${w[$((i+1))]:-}" in -v|-V) i=$n; break ;; esac   # command -v — поиск команды
        wrapper=command ;;
      env) [ "$i" = $((n-1)) ] && break; wrapper=env ;;
      -*) if [ -n "$wrapper" ]; then wrapper_flag_value "$wrapper" "$wi" && i=$((i+1)); else break; fi ;;
      *=*) ;;
      *) if [ -n "$wrapper" ] && [[ "$wi" =~ ^[0-9.]+[smhd]?$ ]]; then :; else break; fi ;;
    esac
    i=$((i+1))
  done
  [ "$i" -lt "$n" ] || continue
  cmd=${w[$i]##*/}
  last_cmd=$cmd
  args=("${w[@]:$((i+1))}")
  na=${#args[@]}

  case "$cmd" in
    cd|pushd)
      if [ "$na" = 0 ]; then t=$HOME
      else t=${args[0]}; fi
      [ "$t" = - ] && t=$prevdir
      # цель раскрываем до смены prevdir: иначе cd "$OLDPWD" раскроется в новый каталог
      d=$(norm "$t" "$curdir"); [ "$d" = "?" ] && d=$CWD
      [ "$cmd" = pushd ] && pstack+=("$curdir")
      prevdir=$curdir
      curdir=$d; continue ;;
    popd)
      if [ ${#pstack[@]} -gt 0 ]; then
        curdir=${pstack[$((${#pstack[@]}-1))]}
        unset "pstack[$((${#pstack[@]}-1))]"; pstack=(${pstack[@]+"${pstack[@]}"})
      else
        curdir=$CWD
      fi
      continue ;;
    git)
      gitdir=$curdir; j=0
      while [ "$j" -lt "$na" ] && [[ "${args[$j]}" == -* ]]; do
        case "${args[$j]}" in
          -C) gitdir=$(norm "${args[$((j+1))]:-.}" "$curdir"); [ "$gitdir" = "?" ] && gitdir=$curdir; j=$((j+2)) ;;
          --git-dir|--work-tree) in_project "${args[$((j+1))]:-.}" "$curdir" && gitdir=$PROOT; j=$((j+2)) ;;
          -c|--namespace) j=$((j+2)) ;;
          --git-dir=*|--work-tree=*) in_project "${args[$j]#*=}" "$curdir" && gitdir=$PROOT; j=$((j+1)) ;;
          *) j=$((j+1)) ;;
        esac
      done
      sub=${args[$j]:-}
      rest=("${args[@]:$((j+1))}")
      case "$sub" in
        push|send-pack) deny "git $sub отправляет код на GitHub — приёмщик и разведчик ничего не отправляют." ;;
        clone)
          # цель — второй позиционный аргумент после URL (флаги со значением пропускаем)
          npos=0; tgt=""; k=0
          while [ "$k" -lt "${#rest[@]}" ]; do
            a=${rest[$k]}
            case "$a" in
              -b|--branch|-o|--origin|--depth|--reference|--reference-if-able|-c|--config|--template|--separate-git-dir|--filter|-j|--jobs|--shallow-since|--shallow-exclude|-u|--upload-pack|--server-option) k=$((k+2)); continue ;;
              -*) ;;
              *) npos=$((npos+1)); [ "$npos" = 2 ] && tgt=$a ;;
            esac
            k=$((k+1))
          done
          if [ -n "$tgt" ]; then write_in_project "$tgt" "$gitdir" && deny "git clone внутрь проекта ($tgt)."
          else in_project . "$gitdir" && deny "git clone без каталога назначения — клон окажется в проекте."; fi ;;
        *)
          if in_project . "$gitdir"; then
            git_read_ok "$sub" ${rest[@]+"${rest[@]}"} || deny "git $sub меняет репозиторий проекта."
          fi ;;
      esac
      continue ;;
    gh)
      gh_check ${args[@]+"${args[@]}"}
      continue ;;
    find)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls) [ "$here_project" = 1 ] && deny "find $a меняет файлы — внутри проекта только поиск." ;; esac
      done
      [ "$here_project" = 1 ] && continue ;;
    cp|rsync|install)
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
      [ -n "$tgt" ] && write_in_project "$tgt" "$curdir" && deny "$cmd в файлы проекта ($tgt)."
      [ -z "$tgt" ] && [ "$here_project" = 1 ] && deny "$cmd без цели внутри проекта."
      continue ;;
    ln)
      # жёсткую ссылку на файл проекта потом по пути не распознать — источник проверяем тоже
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -*) continue ;; esac
        write_in_project "$a" "$curdir" && deny "ln с файлом проекта ($a) — через ссылку можно писать в проект."
      done
      continue ;;
    tee|mkdir|rmdir|rm|touch|mv|chmod)
      # пути только вне проекта (mkdir временной папки, tee в файл во временной папке) — можно
      any=0
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -*) continue ;; esac
        any=1; write_in_project "$a" "$curdir" && deny "$cmd с файлом проекта ($a)."
      done
      [ "$any" = 1 ] || [ "$cmd" = tee ] || [ "$here_project" = 0 ] || deny "$cmd внутри проекта."
      continue ;;
    mktemp)
      # без шаблона, с -t или -p — во временной папке; шаблон без пути — в текущем каталоге
      tmpflag=0
      for a in ${args[@]+"${args[@]}"}; do case "$a" in -t|-p|--tmpdir*) tmpflag=1 ;; esac; done
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in
          -*) ;;
          */*) write_in_project "$a" "$curdir" && deny "mktemp внутри проекта ($a)." ;;
          *) [ "$tmpflag" = 0 ] && [ "$here_project" = 1 ] && deny "mktemp $a создаст файл в каталоге проекта." ;;
        esac
      done
      continue ;;
  esac

  # Читающие команды, которые умеют писать в файл флагом или вторым аргументом.
  wout=""; npos=0
  for a in ${args[@]+"${args[@]}"}; do
    case "$a" in --*) ;; -*) ;; *) npos=$((npos+1)) ;; esac
    case "$cmd:$a" in
      sort:--output*|tree:-o*|file:-C) wout=$a ;;
      sort:--*) ;;
      sort:-*o*) wout=$a ;;
    esac
  done
  case "$cmd" in uniq|xxd) [ "$npos" -ge 2 ] && wout="второй аргумент — файл вывода" ;; esac
  if [ -n "$wout" ] && [ "$here_project" = 1 ]; then deny "$cmd пишет в файл ($wout)."; fi

  case "$READERS" in *" $cmd "*) continue ;; esac

  # Всё остальное (интерпретаторы, сборка, sed, perl, yq, rm, curl …): внутри проекта —
  # нет, во временной папке — да, но без аргументов, указывающих внутрь проекта.
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
