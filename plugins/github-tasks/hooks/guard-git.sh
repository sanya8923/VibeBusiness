#!/usr/bin/env bash
# PreToolUse-хук для Bash: запреты в проектах с процессом github-tasks.
#   1. git add -A / --all / . / -u (и их слитые и сокращённые формы), git commit -a —
#      в коммит попадают чужие и посторонние файлы;
#   2. force push в любой форме и push прямо в основную ветку или в base_branch —
#      перезапись истории и работа мимо PR;
#   3. git commit на основной ветке или на base_branch — работа мимо PR и приёмки.
# Если в настройках задано поле paths (монорепозиторий), запреты 2 и 3 для основной ветки и
# base_branch действуют, только если коммит или отправляемые коммиты трогают эти папки;
# force push, удаление защищённой ветки и запрет 1 — всегда. Чего хук заранее не вычислит
# (состав коммита, диапазон push) — запрещается. Правило целиком — PROCESS.md, раздел
# «Монорепозиторий: поле paths».
# Код 2 — команда заблокирована, причина уходит Claude через stderr.
#
# Команду разбирает tokenize.awk: кавычки, переносы строк, подоболочки, группы,
# подстановки команд и heredoc учтены. Каталог команды — из cd/pushd, git -C и cwd хука;
# ветка — из git switch/checkout ранее в той же команде, иначе текущая. Переменные,
# присвоенные в этой же команде (WT=…, D=$(mktemp -d), ROOT=$(git rev-parse
# --show-toplevel)), а также $PWD, $OLDPWD, $HOME, $TMPDIR раскрываются (common.sh);
# неизвестная переменная — проверяется каталог сессии.
#
# Известные ограничения — обход требует нарочно странной записи:
# - eval, bash -c '…', find … -exec git …, $(which git) add -A — внутрь не разбираются;
# - обратные кавычки внутри двойных, $'…' с \', ${x:-$(git …)} без кавычек, $((1<<2)),
#   $(git …) в теле heredoc с меткой без кавычек;
# - git add ./., git add .>/dev/null, абсолютный путь корня или "$(git rev-parse
#   --show-toplevel)" вместо «.»;
# - git push origin x:heads/main (git сам дописывает до main);
# - git merge на основной ветке (коммит слияния) не запрещается; с paths такой коммит,
#   если он трогает папки процесса, остановит проверка push;
# - псевдонимы git (git ci вместо git commit) не разбираются как подкоманда;
# - env -C <каталог> git … — смену каталога через env хук не отслеживает;
# - очень длинная команда (150+ вызовов git, скрипт на сотни КБ) может не уложиться в
#   таймаут хука 10 с — тогда Claude Code выполнит её без проверки.
set -uo pipefail
set -f  # без подстановки * — разбираем текст команды, а не файлы
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | hk_field tool_input.command)
CWD=$(printf '%s' "$INPUT" | hk_field cwd)
[ -n "$CMD" ] || exit 0
[ -n "$CWD" ] || CWD=$PWD
case "$CMD" in *git*) ;; *) exit 0 ;; esac

deny() {
  echo "github-tasks: $1" >&2
  echo "Правило процесса задач этого проекта (.claude/github-tasks.json). $2" >&2
  exit 2
}

# Короткая группа флагов ($1, например -vA) содержит один из символов $2?
# Символы из $3 берут значение: всё после них — значение, а не флаги.
short_has() {
  local g=${1#-} k ch
  for ((k = 0; k < ${#g}; k++)); do
    ch=${g:$k:1}
    case "$3" in *"$ch"*) return 1 ;; esac
    case "$2" in *"$ch"*) return 0 ;; esac
  done
  return 1
}
# Короткая группа заканчивается флагом, который берёт значение следующим словом?
short_takes_next() {
  local g=${1#-} k ch
  for ((k = 0; k < ${#g}; k++)); do
    ch=${g:$k:1}
    case "$2" in *"$ch"*) [ $k -eq $((${#g} - 1)) ] && return 0 || return 1 ;; esac
  done
  return 1
}

curdir=$CWD; prevdir=$CWD; pstack=()
sw_dir=""; sw_branch=""   # ветка, на которую команда переключилась раньше (switch/checkout)

current_branch() {  # каталог репозитория
  if [ -n "$sw_dir" ] && [ "$(hk_root "$1")" = "$sw_dir" ]; then echo "$sw_branch"; return; fi
  git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# Папки процесса (поле paths). Когда они заданы, коммит и push в основную ветку и в
# base_branch запрещаются, только если затрагивают эти папки. Хук смотрит на команду до
# её запуска, поэтому запоминает, что она делает с индексом и ветками раньше коммита и
# push: пути из git add/rm/mv (ADD_TOP/ADD_REL — рабочая копия и путь от её корня, «?» —
# путь неизвестен), рабочие копии, где индекс меняется непредсказуемо (IDXU), и
# репозитории, где ветки сдвигаются (DIRTY). Чего не вычислить — то запрещается.
PC_ROOT=(); PC_VAL=()   # кэш поля paths по корню репозитория
PATHS=(); PSPEC=()      # папки процесса текущего репозитория и они же как pathspec git
ADD_TOP=(); ADD_REL=(); IDXU=(); DIRTY=()

load_paths() {  # корень репозитория → PATHS, PSPEC
  local k v="" found=0 line
  PATHS=(); PSPEC=()
  for ((k = 0; k < ${#PC_ROOT[@]}; k++)); do
    [ "${PC_ROOT[$k]}" = "$1" ] && { v=${PC_VAL[$k]}; found=1; break; }
  done
  if [ "$found" = 0 ]; then v=$(hk_paths "$1"); PC_ROOT+=("$1"); PC_VAL+=("$v"); fi
  [ -n "$v" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    PATHS+=("$line"); PSPEC+=(":(top)$line")
  done <<<"$v"
}

in_list() {  # значение элементы…
  local x=$1 y; shift
  for y in "$@"; do [ "$y" = "$x" ] && return 0; done
  return 1
}

# Часть пути до первого символа шаблона (*, ?, [), обрезанная до каталога; без шаблона —
# путь как есть. svc/*.py → svc, *.py → пусто (весь репозиторий).
lit_prefix() {
  local p=${1%/} h
  case "$p" in
    *'*'*|*'?'*|*'['*) h=${p%%[*?[]*}; case "$h" in */*) echo "${h%/*}" ;; *) echo "" ;; esac ;;
    *) echo "$p" ;;
  esac
}

# Путь от корня рабочей копии ($1) задевает папки процесса: лежит в одной из них или сам
# содержит её (git add tools задевает tools/vb-hub-bot).
spec_hits() {
  local a b
  a=$(lit_prefix "$1")
  { [ -z "$a" ] || [ "$a" = . ]; } && return 0
  for b in "${PATHS[@]}"; do
    b=$(lit_prefix "$b")
    [ -z "$b" ] && return 0
    case "$a/" in "$b"/*) return 0 ;; esac
    case "$b/" in "$a"/*) return 0 ;; esac
  done
  return 1
}

# Путь из команды ($1, относительно каталога $2) — от корня рабочей копии $3; «?» —
# неизвестен: переменная, магия pathspec (:(top)…, :/…), путь вне рабочей копии.
rel_spec() {
  local abs
  case "$1" in ''|:*) echo "?"; return ;; esac
  abs=$(norm "$1" "$2"); [ "$abs" = "?" ] && { echo "?"; return; }
  [ "$abs" = "$3" ] && { echo .; return; }
  case "$abs" in "$3"/*) echo "${abs#"$3"/}" ;; *) echo "?" ;; esac
}

paths_list() { local IFS=,; echo "${PATHS[*]}" | sed 's/,/, /g'; }

# git add/rm/mv: запомнить пути, которые команда кладёт в индекс.
note_index() {  # подкоманда
  local a j=0 dd=0 inter=0 specs=()
  while [ "$j" -lt "$na" ]; do
    a=${args[$j]}
    if [ "$dd" = 1 ]; then specs+=("$a")
    else
      case "$a" in
        --) dd=1 ;;
        --pathspec-fr*=*) odd=1 ;;
        --pathspec-fr*) odd=1; j=$((j+1)) ;;
        --patc*|--int*|--ed*) [ "$1" = add ] && inter=1 ;;
        --*) ;;
        -?*) [ "$1" = add ] && short_has "$a" "pie" "" && inter=1 ;;
        *) specs+=("$a") ;;
      esac
    fi
    j=$((j+1))
  done
  # -p/-i/-e без путей берут изменения из всей рабочей копии — состав неизвестен
  if [ "$odd" = 1 ] || [ "$top" = "?" ] || { [ "$inter" = 1 ] && [ ${#specs[@]} -eq 0 ]; }; then
    IDXU+=("$top"); return
  fi
  for a in ${specs[@]+"${specs[@]}"}; do
    ADD_TOP+=("$top"); ADD_REL+=("$(rel_spec "$a" "$gitdir" "$top")")
  done
}

# Коммит прямо в защищённую ветку $1 при заданных paths: запрет, если в коммит попадает
# файл из папок процесса или состав коммита не вычислить.
commit_paths_check() {
  local br=$1 a r k hit="" why="" out
  if [ "$top" = "?" ]; then why="не удалось определить рабочую копию"
  elif [ "$odd" = 1 ] || [ "$c_odd" = 1 ]; then
    why="пути коммита берутся из файла, stdin (xargs), интерактивного выбора (-p) или другого индекса (GIT_INDEX_FILE, --git-dir)"
  else
    for a in ${c_specs[@]+"${c_specs[@]}"}; do
      r=$(rel_spec "$a" "$gitdir" "$top")
      if [ "$r" = "?" ]; then why="путь $a не удалось разобрать"; break; fi
      spec_hits "$r" && { hit=$r; break; }
    done
    # git commit <пути> берёт только эти пути; с -i — ещё и всё проиндексированное
    if [ -z "$hit$why" ] && { [ ${#c_specs[@]} -eq 0 ] || [ "$c_inc" = 1 ]; }; then
      if in_list "$top" ${IDXU[@]+"${IDXU[@]}"}; then
        why="раньше в этой же команде индекс меняется так, что состав коммита заранее не известен (stash, reset, pull, restore --staged, git add -p …)"
      fi
      for ((k = 0; k < ${#ADD_TOP[@]}; k++)); do
        [ -z "$hit$why" ] || break
        [ "${ADD_TOP[$k]}" = "$top" ] || continue
        r=${ADD_REL[$k]}
        if [ "$r" = "?" ]; then why="путь, добавленный раньше в этой же команде, не удалось разобрать"
        elif spec_hits "$r"; then hit=$r; fi
      done
      if [ -z "$hit$why" ]; then
        if out=$(git -C "$top" diff --cached --name-only --no-renames -- "${PSPEC[@]}" 2>/dev/null); then
          [ -n "$out" ] && hit=$(printf '%s\n' "$out" | head -1)
        else why="не удалось прочитать индекс (git diff --cached)"; fi
      fi
    fi
    # --amend переписывает последний коммит: его файлы тоже входят в новый
    if [ -z "$hit$why" ] && [ "$c_amend" = 1 ]; then
      if out=$(git -C "$top" diff-tree -m --root --no-commit-id --name-only -r HEAD -- "${PSPEC[@]}" 2>/dev/null); then
        [ -n "$out" ] && hit=$(printf '%s\n' "$out" | head -1)
      else why="не удалось прочитать последний коммит для --amend"; fi
    fi
  fi
  [ -n "$hit" ] && deny "коммит прямо в ветку $br с файлом из папок процесса ($(paths_list)) запрещён: $hit. Эти папки меняются только через PR задачи." \
    "Файлы вне этих папок коммить отдельно от них; файлы папок процесса — в ветке задачи: scripts/claim.sh N, затем scripts/worktree.sh N."
  [ -n "$why" ] && deny "коммит прямо в ветку $br: $why, а файлы из папок процесса ($(paths_list)) в ней коммитить нельзя." \
    "Сначала добавь файлы поимённо отдельной командой (git add путь ...), потом коммить их без -p, --pathspec-from-file и xargs."
  return 0
}

# Push в защищённую ветку $1 при заданных paths: запрет, если отправляемые коммиты
# (от <удалённый>/<ветка> до отправляемого $2) трогают папки процесса или диапазон не
# вычислить. $3 — удалённый репозиторий (пусто — из настроек ветки, иначе origin).
push_paths_check() {
  local dst=$1 src=$2 rem=$3 why="" tr out hit
  [ -n "$rem" ] || rem=$(git -C "$gitdir" config "branch.$dst.remote" 2>/dev/null) || rem=origin
  [ -n "$rem" ] || rem=origin
  tr="refs/remotes/$rem/$dst"
  if in_list "$root" ${DIRTY[@]+"${DIRTY[@]}"}; then
    why="раньше в этой же команде ветки сдвигаются (commit не в эту ветку, merge, rebase, reset, cherry-pick …), и отправляемые коммиты заранее не известны"
  elif [ "$odd" = 1 ]; then why="команда идёт через xargs или с другим каталогом git (--git-dir, GIT_DIR)"
  elif ! git -C "$gitdir" rev-parse -q --verify "$tr^{commit}" >/dev/null 2>&1; then
    why="в локальной копии нет $rem/$dst — не с чем сравнить отправляемые коммиты"
  elif ! git -C "$gitdir" rev-parse -q --verify "$src^{commit}" >/dev/null 2>&1; then
    why="не удалось определить, что отправляется ($src)"
  elif ! out=$(git -C "$gitdir" log --full-history -m --no-renames --name-only --format= "$tr..$src" -- "${PSPEC[@]}" 2>/dev/null); then
    why="не удалось перечислить отправляемые коммиты"
  else
    hit=$(printf '%s\n' "$out" | sed '/^$/d' | head -1)
    [ -n "$hit" ] && deny "push в ветку $dst коммитов, которые трогают папки процесса ($(paths_list)), запрещён: $hit. Эти папки меняются только через PR задачи." \
      "Отправляй ветку задачи issue-N и открывай PR: scripts/open-pr.sh N. Коммиты вне этих папок можно отправить в $dst, если среди отправляемых нет коммитов из папок процесса."
  fi
  [ -n "$why" ] && deny "push в ветку $dst: $why, а коммиты в папки процесса ($(paths_list)) отправлять в неё нельзя." \
    "Разбей на отдельные команды и проверь, что отправляется: git fetch, затем git log $rem/$dst..$src -- <папки>."
  return 0
}

dstack=()   # каталог и ветка до входа в подоболочку: «каталог\037ветка-каталог\037ветка»
while IFS= read -r line; do
  case "$line" in
    $'\003('*) dstack+=("$curdir"$'\037'"$sw_dir"$'\037'"$sw_branch"); continue ;;
    $'\003)'*)
      if [ ${#dstack[@]} -gt 0 ]; then
        top=${dstack[$((${#dstack[@]}-1))]}
        IFS=$'\037' read -r curdir sw_dir sw_branch <<<"$top"
        unset "dstack[$((${#dstack[@]}-1))]"; dstack=(${dstack[@]+"${dstack[@]}"})
      fi
      continue ;;
  esac
  IFS=$'\037' read -r -a raw <<<"$line"
  # команда внутри подстановки: запомнить, чему подстановка равна
  if [ ${#dstack[@]} -gt 0 ]; then subval=$(subst_value ${raw[@]+"${raw[@]}"}); fi
  # Перенаправления tokenize.awk помечает \002 — это не аргументы команды, пропускаем.
  w=()
  for t in ${raw[@]+"${raw[@]}"}; do
    case "$t" in $'\002'*) continue ;; esac
    w+=("$t")
  done
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue
  # Строка из одних присваиваний (можно после export/declare/local/readonly):
  # запомнить переменные (WT=путь, D=$(mktemp -d) …).
  a0=0; case "${w[0]}" in export|declare|local|readonly|typeset) a0=1 ;; esac
  allassign=1
  for t in "${w[@]:$a0}"; do case "$t" in [A-Za-z_]*=*) ;; -*) ;; *) allassign=0 ;; esac; done
  if [ "$allassign" = 1 ] && [ "$n" -gt "$a0" ]; then
    for t in "${w[@]:$a0}"; do case "$t" in -*) continue ;; esac; VARN+=("${t%%=*}"); VARV+=("$(expand_value "${t#*=}")"); done
    continue
  fi
  i=0
  # Служебные слова, присваивания и обёртки перед командой.
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      if|then|else|elif|fi|do|done|while|until|'!') i=$((i+1)) ;;
      -*) break ;;
      *=*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  name=${w[$i]##*/}
  # Обёртка (timeout 30, nice -n 5, sudo -E, env -u X, xargs -0 …): у неё свои флаги и
  # аргументы, поэтому сама команда — первое следующее слово, которое и есть git.
  case "$name" in
    time|command|builtin|exec|nohup|nice|sudo|doas|xargs|env|timeout|gtimeout|stdbuf|ionice|caffeinate|chronic|unbuffer|arch)
      # Пропускаем флаги обёртки, их значения, числа и длительности, VAR=…, вложенные
      # обёртки. Первое другое слово — это уже не git, а иная команда (echo git … — текст).
      k=$((i+1)); pf=0; found=""
      while [ "$k" -lt "$n" ]; do
        wk=${w[$k]}
        if [ "${wk##*/}" = git ]; then found=$k; break; fi
        case "$wk" in
          time|command|builtin|exec|nohup|nice|sudo|doas|xargs|env|timeout|gtimeout|stdbuf|ionice|caffeinate|chronic|unbuffer|arch) pf=0 ;;
          -?) pf=1 ;;
          --*=*) pf=0 ;;
          --*) pf=1 ;;   # длинный флаг без «=» может взять значение следующим словом
          -*) pf=0 ;;
          *=*) pf=0 ;;
          *) if [[ "$wk" =~ ^[0-9.]+[smhd]?$ ]]; then pf=0
             elif [ "$pf" = 1 ]; then pf=0
             else break; fi ;;
        esac
        k=$((k+1))
      done
      [ -n "$found" ] || continue
      i=$found; name=git ;;
  esac

  case "$name" in
    cd|pushd)
      # каталог раскрываем с переменными этой команды; неизвестный — каталог сессии
      # (осторожная сторона: проверяется основная копия)
      if [ $((i+1)) -lt "$n" ]; then t=${w[$((i+1))]}; else t=$HOME; fi
      [ "$t" = - ] && t=$prevdir
      d=$(norm "$t" "$curdir"); [ "$d" = "?" ] && d=$CWD
      # несуществующий каталог: cd не сработает, команда продолжится в прежнем
      dir_reachable "$d" || continue
      [ "$name" = pushd ] && pstack+=("$curdir")
      prevdir=$curdir; curdir=$d
      continue ;;
    mkdir)
      for t in "${w[@]:$((i+1))}"; do case "$t" in -*) ;; *) MKDIRS+=("$(norm "$t" "$curdir")") ;; esac; done
      continue ;;
    popd)
      if [ ${#pstack[@]} -gt 0 ]; then
        prevdir=$curdir; curdir=${pstack[$((${#pstack[@]}-1))]}
        unset "pstack[$((${#pstack[@]}-1))]"; pstack=(${pstack[@]+"${pstack[@]}"})
      else
        curdir=$CWD
      fi
      continue ;;
    git) ;;
    *) continue ;;
  esac

  gitdir=$curdir
  gi=$i; godd=0   # где в строке слово git; есть ли --git-dir/--work-tree
  i=$((i+1))
  while [ "$i" -lt "$n" ] && [[ "${w[$i]}" == -* ]]; do
    case "${w[$i]}" in
      -C) d=$(norm "${w[$((i+1))]:-.}" "$curdir"); [ "$d" = "?" ] && d=$CWD; gitdir=$d; i=$((i+2)) ;;
      --git-dir|--work-tree) godd=1; i=$((i+2)) ;;
      --git-dir=*|--work-tree=*) godd=1; i=$((i+1)) ;;
      -c|--namespace|--exec-path) i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  sub=${w[$i]}
  # ещё не созданный каталог (mkdir в этой же команде) — по ближайшему родителю
  gd=$(real_dir "$gitdir"); [ -n "$gd" ] || continue
  gitdir=$gd
  root=$(hk_root "$gitdir")
  [ -n "$root" ] && hk_enabled "$root" || continue
  base=$(hk_base_branch "$root")
  default=$(hk_default_branch "$root")
  args=("${w[@]:$((i+1))}")
  na=${#args[@]}
  if [ "$sub" = clone ]; then
    t=$(clone_target ${args[@]+"${args[@]}"}); [ -n "$t" ] && CLONED+=("$(norm "$t" "$gitdir")")
    continue
  fi

  # Папки процесса: корень рабочей копии и признаки, что пути и ветки не вычислить.
  load_paths "$root"
  top="?"; odd=$godd
  if [ ${#PATHS[@]} -gt 0 ]; then
    t=$(git -C "$gitdir" rev-parse --show-toplevel 2>/dev/null) && top=$(norm "$t" /)
    for ((k = 0; k < gi; k++)); do
      case "${w[$k]}" in GIT_DIR=*|GIT_WORK_TREE=*|GIT_INDEX_FILE=*|GIT_COMMON_DIR=*|GIT_OBJECT_DIRECTORY=*) odd=1 ;; esac
      [ "${w[$k]##*/}" = xargs ] && odd=1   # аргументы придут из stdin
    done
    for t in ${VARN[@]+"${VARN[@]}"}; do
      case "$t" in GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY) odd=1 ;; esac
    done
  fi

  case "$sub" in
    add)
      j=0; dashdash=0
      while [ "$j" -lt "$na" ]; do
        a=${args[$j]}
        if [ "$dashdash" = 0 ]; then
          case "$a" in
            --) dashdash=1; j=$((j+1)); continue ;;
            --pathspec-from-file) j=$((j+2)); continue ;;
            --a|--al|--all|--u|--up|--upd|--upda|--updat|--update|--no-ignore-r*)
              deny "git add $a запрещён: в коммит попадут чужие и посторонние файлы." \
                   "Добавляй файлы задачи поимённо: git add путь/к/файлу ..." ;;
            --*) ;;
            -?*) short_has "$a" "Au" "" && deny "git add $a запрещён: флаг -A или -u добавляет все изменения разом." \
                   "Добавляй файлы задачи поимённо: git add путь/к/файлу ..." ;;
          esac
        fi
        case "$a" in
          .|./|:/|:/.|'*'|'./*'|':(top)'|':/*')
            deny "git add $a запрещён: в коммит попадут чужие и посторонние файлы." \
                 "Добавляй файлы задачи поимённо: git add путь/к/файлу ..." ;;
        esac
        j=$((j+1))
      done
      [ ${#PATHS[@]} -gt 0 ] && note_index add ;;

    rm|mv) [ ${#PATHS[@]} -gt 0 ] && note_index "$sub" ;;

    switch|checkout)
      # Запоминаем, на какую ветку команда переключается, — для проверки коммита ниже.
      j=0; target=""; extra=0
      while [ "$j" -lt "$na" ]; do
        a=${args[$j]}
        case "$a" in
          --) target=""; break ;;
          -c|-C|-b|-B|--create|--force-create|--orphan) target=${args[$((j+1))]:-}; break ;;
          -*) ;;
          *) if [ -n "$target" ]; then extra=1
             else
               # git checkout <файл> — не переход на ветку: считаем веткой, только если она есть
               if git -C "$gitdir" rev-parse -q --verify "refs/heads/$a" >/dev/null 2>&1 \
                  || git -C "$gitdir" rev-parse -q --verify "refs/remotes/origin/$a" >/dev/null 2>&1; then
                 target=$a
               fi
             fi ;;
        esac
        j=$((j+1))
      done
      # git checkout <ветка> <пути> восстанавливает файлы и не меняет ветку.
      if [ -n "$target" ] && [ "$extra" = 0 ]; then sw_dir=$root; sw_branch=$target; fi
      if [ ${#PATHS[@]} -gt 0 ]; then
        # -B/-C пересоздают существующую ветку — она сдвигается.
        # git checkout <коммит> [--] <пути> и checkout -p кладут файлы в индекс.
        npos=0; nbefore=0; seendd=0; creating=0
        for a in ${args[@]+"${args[@]}"}; do
          case "$a" in
            -B|-C|--force-c*) DIRTY+=("$root"); creating=1 ;;
            -b|-c|--orphan|--create) creating=1 ;;
            -p|--patch|--pat*) [ "$sub" = checkout ] && IDXU+=("$top") ;;
            --) seendd=1 ;;
            -*) ;;
            *) npos=$((npos+1)); [ "$seendd" = 0 ] && nbefore=$((nbefore+1)) ;;
          esac
        done
        if [ "$sub" = checkout ] && [ "$creating" = 0 ]; then
          if { [ "$seendd" = 1 ] && [ "$nbefore" -ge 1 ] && [ "$npos" -gt "$nbefore" ]; } \
             || { [ "$seendd" = 0 ] && [ "$npos" -ge 2 ]; }; then IDXU+=("$top"); fi
        fi
      fi ;;

    commit)
      j=0; c_inc=0; c_amend=0; c_odd=0; c_specs=()
      while [ "$j" -lt "$na" ]; do
        a=${args[$j]}
        case "$a" in
          --) c_specs+=("${args[@]:$((j+1))}"); break ;;
          --all) deny "git commit --all запрещён: в коммит попадут все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a." ;;
          --pathspec-fr*=*) c_odd=1 ;;
          --pathspec-fr*) c_odd=1; j=$((j+1)) ;;
          --message|--file|--reuse-message|--reedit-message|--template|--author|--date|--fixup|--squash|--trailer|--cleanup) j=$((j+1)) ;;
          --am|--ame|--amen|--amend) c_amend=1 ;;
          --inc*) c_inc=1 ;;
          --patc*|--int*) c_odd=1 ;;
          --*) ;;
          -?*)
            short_has "$a" "a" "mFCct" && deny "git commit $a запрещён: флаг -a добавляет в коммит все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a."
            short_has "$a" "i" "mFCct" && c_inc=1
            short_has "$a" "p" "mFCct" && c_odd=1
            short_takes_next "$a" "mFCct" && j=$((j+1)) ;;
          *) c_specs+=("$a") ;;
        esac
        j=$((j+1))
      done
      br=$(current_branch "$gitdir")
      if [ -n "$br" ] && { [ "$br" = "$default" ] || [ "$br" = "$base" ]; }; then
        if [ ${#PATHS[@]} -eq 0 ]; then
          deny "коммит прямо в ветку $br запрещён: работа должна идти через PR задачи." \
               "Возьми задачу и работай в её ветке: scripts/claim.sh N, затем scripts/worktree.sh N."
        fi
        commit_paths_check "$br"
      elif [ ${#PATHS[@]} -gt 0 ]; then
        DIRTY+=("$root")   # коммит в другую ветку: её push в основную уже не вычислить заранее
      fi
      # Обычный коммит забирает всё проиндексированное: добавленное раньше уже не в индексе.
      if [ ${#PATHS[@]} -gt 0 ] && [ ${#c_specs[@]} -eq 0 ]; then
        nt=(); nr=()
        for ((k = 0; k < ${#ADD_TOP[@]}; k++)); do
          [ "${ADD_TOP[$k]}" = "$top" ] && continue
          nt+=("${ADD_TOP[$k]}"); nr+=("${ADD_REL[$k]}")
        done
        ADD_TOP=(${nt[@]+"${nt[@]}"}); ADD_REL=(${nr[@]+"${nr[@]}"})
      fi ;;

    push)
      j=0; pos=0; tags=0; remote=""; pdel=0
      # Удаление ветки (-d, --delete) может стоять после refspec — ищем заранее.
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in
          --de*) pdel=1 ;;
          --*) ;;
          -?*) short_has "$a" "d" "o" && pdel=1 ;;
        esac
      done
      while [ "$j" -lt "$na" ]; do
        a=${args[$j]}
        case "$a" in
          --al|--all)
            deny "git push $a запрещён: отправляет все ветки, включая основную." "Отправляй только ветку задачи: git push -u origin issue-N." ;;
          --for*|--mi|--mir|--mirr|--mirro|--mirror)
            deny "git push $a запрещён: перезапись истории на GitHub уничтожает чужую работу." "Если push отклонён — забери изменения (git pull --rebase) и отправь снова без force." ;;
          --tags) tags=1 ;;
          --repo|--receive-pack|--exec|--push-option) j=$((j+1)) ;;
          --*) ;;
          -?*)
            short_has "$a" "f" "o" && deny "git push $a запрещён: -f — это force push." "Если push отклонён — забери изменения (git pull --rebase) и отправь снова без force."
            short_takes_next "$a" "o" && j=$((j+1)) ;;
          *)
            pos=$((pos+1))
            [ "$pos" = 1 ] && remote=$a
            if [ "$pos" -ge 2 ]; then   # первое позиционное — remote, дальше — refspec
              case "$a" in +*) deny "git push $a запрещён: «+» перед веткой — это force push." "Отправляй ветку без «+»." ;; esac
              case "$a" in
                :|*'*'*) deny "git push $a запрещён: отправляет все совпадающие ветки, включая основную." "Отправляй только ветку задачи: git push -u origin issue-N." ;;
              esac
              dst=${a#*:}; dst=${dst#refs/heads/}
              src=${a%%:*}; [ "$a" = "${a#*:}" ] && src=$a
              [ "$dst" = HEAD ] && dst=$(current_branch "$gitdir")
              if [ "$src" = HEAD ]; then t=$(current_branch "$gitdir"); [ -n "$t" ] && src=$t; fi
              if [ "$dst" = "$default" ] || { [ -n "$base" ] && [ "$dst" = "$base" ]; }; then
                if [ ${#PATHS[@]} -eq 0 ]; then
                  deny "git push $a запрещён: это отправка прямо в ветку $dst мимо PR." \
                       "Отправляй ветку задачи issue-N и открывай PR: scripts/open-pr.sh N."
                fi
                { [ -z "$src" ] || [ "$pdel" = 1 ]; } && deny "удаление ветки $dst на GitHub запрещено (git push $a$([ "$pdel" = 1 ] && echo ' с --delete'))." \
                     "Основную ветку и base_branch не удаляют; ветку задачи удаляет слияние PR."
                push_paths_check "$dst" "$src" "$remote"
              fi
            fi ;;
        esac
        j=$((j+1))
      done
      # Без refspec push отправляет текущую ветку — проверяем её.
      if [ "$pos" -lt 2 ] && [ "$tags" = 0 ]; then
        cur=$(current_branch "$gitdir")
        if [ -n "$cur" ] && { [ "$cur" = "$default" ] || { [ -n "$base" ] && [ "$cur" = "$base" ]; }; }; then
          if [ ${#PATHS[@]} -eq 0 ]; then
            deny "git push с ветки $cur — это отправка прямо в неё мимо PR." \
                 "Работай в ветке задачи issue-N и открывай PR: scripts/open-pr.sh N."
          fi
          [ "$pdel" = 1 ] && deny "git push --delete с ветки $cur запрещён." "Основную ветку и base_branch не удаляют."
          push_paths_check "$cur" "$cur" "$remote"
        fi
      fi ;;

    # Дальше — только учёт для папок процесса: что команда делает с индексом и ветками.
    restore)
      if [ ${#PATHS[@]} -gt 0 ]; then
        for a in ${args[@]+"${args[@]}"}; do
          case "$a" in
            --sta*) IDXU+=("$top") ;;
            --*) ;;
            -?*) short_has "$a" "S" "s" && IDXU+=("$top") ;;
          esac
        done
      fi ;;
    branch)
      if [ ${#PATHS[@]} -gt 0 ]; then
        for a in ${args[@]+"${args[@]}"}; do
          case "$a" in
            --for*|--mo*|--cop*) DIRTY+=("$root") ;;
            --*) ;;
            -?*) short_has "$a" "fmMcC" "" && DIRTY+=("$root") ;;
          esac
        done
      fi ;;
    fetch)
      # fetch с refspec «откуда:куда» может сдвинуть локальную ветку
      if [ ${#PATHS[@]} -gt 0 ]; then
        for a in ${args[@]+"${args[@]}"}; do case "$a" in -*) ;; *:*) DIRTY+=("$root") ;; esac; done
      fi ;;
    worktree)
      if [ ${#PATHS[@]} -gt 0 ]; then
        for a in ${args[@]+"${args[@]}"}; do [ "$a" = -B ] && DIRTY+=("$root"); done
      fi ;;
    # Ничего не меняют ни в индексе, ни в ветках.
    status|diff|log|show|rev-parse|rev-list|ls-files|ls-tree|ls-remote|cat-file|config|remote|describe|blame|grep|shortlog|show-ref|for-each-ref|symbolic-ref|merge-base|name-rev|reflog|help|version|var|check-ignore|check-attr|count-objects|fsck|gc|prune|repack|maintenance|whatchanged|archive|format-patch|range-diff|cherry|show-branch|verify-commit|verify-tag|difftool|tag|notes|init|clean) ;;
    # pull и stash меняют индекс, но отправляемые потом коммиты — те же локальные.
    pull|stash|apply|update-index|read-tree) [ ${#PATHS[@]} -gt 0 ] && IDXU+=("$top") ;;
    # merge, rebase, reset, cherry-pick, revert, am, update-ref, псевдонимы git и прочее
    *) if [ ${#PATHS[@]} -gt 0 ]; then IDXU+=("$top"); DIRTY+=("$root"); fi ;;
  esac
done < <(printf '%s' "$CMD" | awk -f "$HERE/tokenize.awk")
exit 0
