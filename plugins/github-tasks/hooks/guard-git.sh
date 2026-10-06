#!/usr/bin/env bash
# PreToolUse-хук для Bash: три запрета в проектах с процессом github-tasks.
#   1. git add -A / --all / . / -u и git commit -a — в коммит попадают чужие файлы;
#   2. любой force push — переписывает историю на GitHub, чужая работа теряется;
#   3. git commit на основной ветке или на base_branch — работа идёт мимо PR и приёмки.
# Код 2 — команда заблокирована, причина уходит Claude через stderr.
#
# Команда разбирается по тексту, поэтому разбор приближённый:
# - текст в кавычках и тела heredoc не разбираются — «git add -A» внутри сообщения
#   коммита запретом не считается;
# - каталог команды берётся из `cd ДИР`, `git -C ДИР` и cwd хука; путь из переменной
#   ($DIR) не раскрывается, тогда проверяется cwd.
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

# 1) выкинуть тела heredoc; 2) снять кавычки, заменив внутри них пробелы и
#    разделители команд на «_»; 3) разбить на отдельные команды по ; & | и переводу строки.
SEGMENTS=$(printf '%s\n' "$CMD" | awk '
  skip != "" { if ($0 ~ "^[[:space:]]*" skip "[[:space:]]*$") skip = ""; next }
  {
    line = $0
    if (match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      tag = substr(line, RSTART, RLENGTH); gsub(/<<-?[[:space:]]*|["\047]/, "", tag); skip = tag
      line = substr(line, 1, RSTART - 1)
    }
    out = ""; q = ""
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q == "" && (c == "\"" || c == "\047")) { q = c; continue }
      if (q != "" && c == q) { q = ""; continue }
      if (q != "" && (c == " " || c == ";" || c == "&" || c == "|")) c = "_"
      out = out c
    }
    gsub(/&&|\|\||;|\||&/, "\n", out)
    print out
  }')

resolve() {  # путь $1 относительно каталога $2
  case "$1" in
    /*) echo "$1" ;;
    "~"*) echo "$HOME${1#\~}" ;;
    *) echo "$2/$1" ;;
  esac
}

curdir=$CWD
while IFS= read -r seg; do
  # shellcheck disable=SC2206
  w=($seg)
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue
  i=0
  while [ "$i" -lt "$n" ] && [[ "${w[$i]}" == *=* ]] && [[ "${w[$i]}" != -* ]]; do i=$((i+1)); done
  [ "$i" -lt "$n" ] || continue

  if [ "${w[$i]}" = cd ]; then
    if [ $((i+1)) -lt "$n" ]; then
      d=$(resolve "${w[$((i+1))]}" "$curdir"); [ -d "$d" ] && curdir=$d
    else
      curdir=$HOME
    fi
    continue
  fi
  [ "${w[$i]}" = git ] || continue

  gitdir=$curdir
  i=$((i+1))
  while [ "$i" -lt "$n" ] && [[ "${w[$i]}" == -* ]]; do
    case "${w[$i]}" in
      -C) d=$(resolve "${w[$((i+1))]:-.}" "$curdir"); [ -d "$d" ] && gitdir=$d; i=$((i+2)) ;;
      -c|--git-dir|--work-tree|--namespace) i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  sub=${w[$i]}
  root=$(hk_root "$gitdir")
  [ -n "$root" ] && hk_enabled "$root" || continue

  args=("${w[@]:$((i+1))}")
  case "$sub" in
    add)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in
          -A|--all|-u|--update|.|./|:/|'*')
            deny "git add $a запрещён: в коммит попадут чужие и посторонние файлы." \
                 "Добавляй файлы задачи поимённо: git add путь/к/файлу ..." ;;
        esac
      done ;;
    commit)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in
          --all) deny "git commit --all запрещён: в коммит попадут все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a." ;;
          --*) ;;
          -*a*) deny "git commit $a запрещён: флаг -a добавляет в коммит все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a." ;;
        esac
      done
      br=$(git -C "$gitdir" symbolic-ref -q --short HEAD 2>/dev/null || true)
      base=$(hk_base_branch "$root")
      default=$(hk_default_branch "$root")
      if [ -n "$br" ] && { [ "$br" = "$default" ] || [ "$br" = "$base" ]; }; then
        deny "коммит прямо в ветку $br запрещён: работа должна идти через PR задачи." \
             "Возьми задачу и работай в её ветке: scripts/claim.sh N, затем scripts/worktree.sh N."
      fi ;;
    push)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in
          --force|--force-with-lease*|--force-if-includes|--mirror)
            deny "git push $a запрещён: перезапись истории на GitHub уничтожает чужую работу." "Если push отклонён — забери изменения (git pull --rebase) и отправь снова без force." ;;
          --*) ;;
          -*f*) deny "git push $a запрещён: -f — это force push." "Если push отклонён — забери изменения (git pull --rebase) и отправь снова без force." ;;
          +*) deny "git push $a запрещён: «+» перед веткой — это force push." "Отправляй ветку без «+»." ;;
        esac
      done ;;
  esac
done <<<"$SEGMENTS"
exit 0
