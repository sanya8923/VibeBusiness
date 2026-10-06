#!/usr/bin/env bash
# PreToolUse-хук: приёмщик и разведчик плагина не меняют проект.
#
# Агенту из плагина нельзя задать собственные хуки и нельзя ограничить Bash отдельными
# командами, а Bash приёмщику нужен — запускать проверки. Поэтому ограничение — здесь:
# хук видит тип субагента (поле agent_type) и для github-tasks:reviewer и
# github-tasks:scout запрещает:
#   - инструменты правки файлов (Edit, Write, NotebookEdit);
#   - в Bash — правку файлов на месте (sed -i, perl -i), запись перенаправлением и tee,
#     rm/mv/cp/touch/mkdir/chmod/ln/truncate — если цель не во временной папке;
#   - git, меняющий репозиторий (add, commit, push, merge, reset…), — кроме копий во
#     временной папке, где приёмщик разворачивает ветку PR;
#   - gh, меняющий GitHub (слияние и правка PR, правка задач и меток, gh api с записью).
#     Разрешено одно действие с записью: комментарий в PR — так публикуется вердикт.
# Команду разбирает тот же tokenize.awk, что и для guard-git.sh. Цель хука — не дать
# агенту «просто поправить», а не защититься от злонамеренного обхода: eval, bash -c,
# python -c и подобные внутрь не разбираются.
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
  echo "Найденный дефект опиши в вердикте или ответе, исправляет исполнитель задачи." >&2
  exit 2
}

case "$TOOL" in
  Edit|Write|NotebookEdit|MultiEdit) deny "инструмент $TOOL правит файлы." ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | hk_field tool_input.command)
[ -n "$CMD" ] || exit 0

PROOT=$(hk_root "$CWD")   # проект, в котором работает сессия

# Можно ли агенту писать по пути $1 (абсолютному или от каталога $2): только вне проекта
# сессии и только во временной папке — там приёмщик разворачивает копию ветки PR.
is_temp() {
  local p=$1
  case "$p" in /*) ;; "~"*) p="$HOME${p#\~}" ;; *) p="$2/$p" ;; esac
  case "$p" in /dev/null|/dev/stdout|/dev/stderr) return 0 ;; esac
  [ -n "$PROOT" ] && case "$p/" in "$PROOT"/*) return 1 ;; esac
  case "$p" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
  esac
  [ -n "${TMPDIR:-}" ] && case "$p" in "${TMPDIR%/}"/*) return 0 ;; esac
  return 1
}

curdir=$CWD
while IFS= read -r line; do
  IFS=$'\037' read -r -a w <<<"$line"
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue

  # Запись перенаправлением: «> файл», «>> файл», «>файл».
  for ((k = 0; k < n; k++)); do
    t=${w[$k]}
    case "$t" in
      '>'|'>>'|'1>'|'2>'|'&>'|'1>>'|'2>>') tgt=${w[$((k+1))]:-} ;;
      '>&'*|'2>&'*) continue ;;
      '>>'*) tgt=${t#>>} ;;
      '>'*|'1>'*|'2>'*) tgt=${t#*>} ;;
      *) continue ;;
    esac
    [ -n "$tgt" ] && ! is_temp "$tgt" "$curdir" && deny "запись в файл $tgt."
  done

  # Сама команда: пропускаем служебные слова, присваивания, обёртки с их флагами,
  # значениями флагов и числами (sudo -u x, timeout 30, nice -n 5 …).
  i=0; pf=0
  while [ "$i" -lt "$n" ]; do
    wi=${w[$i]}
    case "$wi" in
      if|then|else|elif|fi|do|done|while|until|'!') pf=0 ;;
      time|command|builtin|exec|nohup|nice|sudo|doas|xargs|env|timeout|gtimeout|stdbuf|ionice|caffeinate|chronic|unbuffer|arch) pf=0 ;;
      -?) [ "$i" -gt 0 ] && pf=1 || break ;;
      -*) [ "$i" -gt 0 ] && pf=0 || break ;;
      *=*) pf=0 ;;
      *) if [ "$i" -gt 0 ] && [[ "$wi" =~ ^[0-9.]+[smhd]?$ ]]; then pf=0
         elif [ "$pf" = 1 ]; then pf=0
         else break; fi ;;
    esac
    i=$((i+1))
  done
  [ "$i" -lt "$n" ] || continue
  cmd=${w[$i]##*/}
  args=("${w[@]:$((i+1))}")

  case "$cmd" in
    cd)
      d=${args[0]:-$HOME}; case "$d" in /*) ;; *) d="$curdir/$d" ;; esac
      [ -d "$d" ] && curdir=$d ;;
    sed|perl)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -i*|-pi*|--in-place*) deny "$cmd $a правит файл на месте." ;; esac
      done ;;
    tee|rm|mv|cp|touch|mkdir|chmod|chown|ln|truncate|install|rsync)
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -*) continue ;; esac
        is_temp "$a" "$curdir" || deny "$cmd $a меняет файлы вне временной папки."
      done ;;
    git)
      gitdir=$curdir; j=0
      while [ "$j" -lt "${#args[@]}" ] && [[ "${args[$j]}" == -* ]]; do
        if [ "${args[$j]}" = -C ]; then
          d=${args[$((j+1))]:-.}; case "$d" in /*) ;; *) d="$curdir/$d" ;; esac; gitdir=$d; j=$((j+2))
        elif [ "${args[$j]}" = -c ]; then j=$((j+2)); else j=$((j+1)); fi
      done
      sub=${args[$j]:-}
      case "$sub" in
        add|commit|push|merge|rebase|reset|restore|checkout|switch|stash|cherry-pick|revert|apply|am|rm|mv|clean|tag|branch|worktree|pull|fetch|init|clone)
          # Копия во временной папке вне проекта — рабочее место приёмщика: там можно всё.
          is_temp "$gitdir/x" / && [ "$(hk_root "$gitdir")" != "$PROOT" ] && continue
          case "$sub" in
            clone) continue ;;   # клонирование создаёт копию — куда, проверяет is_temp ниже
            fetch|pull) continue ;;
            branch) case " ${args[*]} " in *" -d "*|*" -D "*|*" -m "*|*" -M "*|*" --delete "*) ;; *) continue ;; esac ;;
          esac
          deny "git $sub меняет репозиторий проекта." ;;
      esac ;;
    gh)
      g1=${args[0]:-}; g2=${args[1]:-}
      case "$g1 $g2" in
        "pr merge"|"pr close"|"pr edit"|"pr ready"|"pr reopen"|"pr review"|"pr create"|"issue edit"|"issue close"|"issue create"|"issue delete"|"issue reopen"|"issue transfer"|"label "*|"release "*|"repo "*)
          case "$g1 $g2" in "label list"|"release list"|"release view"|"repo view"|"repo clone") ;; *) deny "gh $g1 $g2 меняет GitHub." ;; esac ;;
        "api "*)
          for a in ${args[@]+"${args[@]}"}; do
            case "$a" in
              -X|--method) ;;
              POST|PATCH|PUT|DELETE|-XPOST|-XPATCH|-XPUT|-XDELETE|-f|-F|--field|--raw-field|--input)
                deny "gh api с записью меняет GitHub." ;;
            esac
          done ;;
      esac ;;
  esac
done < <(printf '%s' "$CMD" | awk -f "$HERE/tokenize.awk")
exit 0
