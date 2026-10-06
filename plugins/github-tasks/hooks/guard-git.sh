#!/usr/bin/env bash
# PreToolUse-хук для Bash: запреты в проектах с процессом github-tasks.
#   1. git add -A / --all / . / -u (и их слитые и сокращённые формы), git commit -a —
#      в коммит попадают чужие и посторонние файлы;
#   2. force push в любой форме и push прямо в основную ветку или в base_branch —
#      перезапись истории и работа мимо PR;
#   3. git commit на основной ветке или на base_branch — работа мимо PR и приёмки.
# Код 2 — команда заблокирована, причина уходит Claude через stderr.
#
# Команду разбирает tokenize.awk: кавычки, переносы строк, подоболочки, группы,
# подстановки команд и heredoc учтены. Каталог команды — из cd/pushd, git -C и cwd хука;
# ветка — из git switch/checkout ранее в той же команде, иначе текущая. Путь из
# переменной ($DIR) не раскрывается — тогда проверяется каталог сессии.
#
# Известные ограничения — обход требует нарочно странной записи:
# - eval, bash -c '…', find … -exec git …, $(which git) add -A — внутрь не разбираются;
# - обратные кавычки внутри двойных, $'…' с \', ${x:-$(git …)} без кавычек, $((1<<2)),
#   $(git …) в теле heredoc с меткой без кавычек;
# - git add ./., git add .>/dev/null, абсолютный путь корня или "$(git rev-parse
#   --show-toplevel)" вместо «.»;
# - git push origin x:heads/main (git сам дописывает до main);
# - git merge на основной ветке (коммит слияния) не запрещается;
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

resolve() {  # путь $1 относительно каталога $2
  case "$1" in
    /*) echo "$1" ;;
    "~"*) echo "$HOME${1#\~}" ;;
    *) echo "$2/$1" ;;
  esac
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

curdir=$CWD
sw_dir=""; sw_branch=""   # ветка, на которую команда переключилась раньше (switch/checkout)

current_branch() {  # каталог репозитория
  if [ -n "$sw_dir" ] && [ "$(hk_root "$1")" = "$sw_dir" ]; then echo "$sw_branch"; return; fi
  git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || true
}

while IFS= read -r line; do
  IFS=$'\037' read -r -a raw <<<"$line"
  # Перенаправления tokenize.awk помечает \002 — это не аргументы команды, пропускаем.
  w=()
  for t in ${raw[@]+"${raw[@]}"}; do
    case "$t" in $'\002'*) continue ;; esac
    w+=("$t")
  done
  n=${#w[@]}
  [ "$n" -gt 0 ] || continue
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
      if [ $((i+1)) -lt "$n" ]; then
        d=$(resolve "${w[$((i+1))]}" "$curdir"); [ -d "$d" ] && curdir=$d
      else
        curdir=$HOME
      fi
      continue ;;
    git) ;;
    *) continue ;;
  esac

  gitdir=$curdir
  i=$((i+1))
  while [ "$i" -lt "$n" ] && [[ "${w[$i]}" == -* ]]; do
    case "${w[$i]}" in
      -C) d=$(resolve "${w[$((i+1))]:-.}" "$curdir"); [ -d "$d" ] && gitdir=$d; i=$((i+2)) ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  sub=${w[$i]}
  root=$(hk_root "$gitdir")
  [ -n "$root" ] && hk_enabled "$root" || continue
  base=$(hk_base_branch "$root")
  default=$(hk_default_branch "$root")
  args=("${w[@]:$((i+1))}")
  na=${#args[@]}

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
      done ;;

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
      if [ -n "$target" ] && [ "$extra" = 0 ]; then sw_dir=$root; sw_branch=$target; fi ;;

    commit)
      j=0
      while [ "$j" -lt "$na" ]; do
        a=${args[$j]}
        case "$a" in
          --) break ;;
          --all) deny "git commit --all запрещён: в коммит попадут все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a." ;;
          --message|--file|--reuse-message|--reedit-message|--template|--author|--date|--fixup|--squash|--trailer|--pathspec-from-file|--cleanup) j=$((j+1)) ;;
          --*) ;;
          -?*)
            short_has "$a" "a" "mFCct" && deny "git commit $a запрещён: флаг -a добавляет в коммит все изменённые файлы." "Добавь файлы задачи поимённо через git add и коммить без -a."
            short_takes_next "$a" "mFCct" && j=$((j+1)) ;;
        esac
        j=$((j+1))
      done
      br=$(current_branch "$gitdir")
      if [ -n "$br" ] && { [ "$br" = "$default" ] || [ "$br" = "$base" ]; }; then
        deny "коммит прямо в ветку $br запрещён: работа должна идти через PR задачи." \
             "Возьми задачу и работай в её ветке: scripts/claim.sh N, затем scripts/worktree.sh N."
      fi ;;

    push)
      j=0; pos=0; tags=0
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
            if [ "$pos" -ge 2 ]; then   # первое позиционное — remote, дальше — refspec
              case "$a" in +*) deny "git push $a запрещён: «+» перед веткой — это force push." "Отправляй ветку без «+»." ;; esac
              case "$a" in
                :|*'*'*) deny "git push $a запрещён: отправляет все совпадающие ветки, включая основную." "Отправляй только ветку задачи: git push -u origin issue-N." ;;
              esac
              dst=${a#*:}; dst=${dst#refs/heads/}
              [ "$dst" = HEAD ] && dst=$(current_branch "$gitdir")
              if [ "$dst" = "$default" ] || { [ -n "$base" ] && [ "$dst" = "$base" ]; }; then
                deny "git push $a запрещён: это отправка прямо в ветку $dst мимо PR." \
                     "Отправляй ветку задачи issue-N и открывай PR: scripts/open-pr.sh N."
              fi
            fi ;;
        esac
        j=$((j+1))
      done
      # Без refspec push отправляет текущую ветку — проверяем её.
      if [ "$pos" -lt 2 ] && [ "$tags" = 0 ]; then
        cur=$(current_branch "$gitdir")
        if [ -n "$cur" ] && { [ "$cur" = "$default" ] || { [ -n "$base" ] && [ "$cur" = "$base" ]; }; }; then
          deny "git push с ветки $cur — это отправка прямо в неё мимо PR." \
               "Работай в ветке задачи issue-N и открывай PR: scripts/open-pr.sh N."
        fi
      fi ;;
  esac
done < <(printf '%s' "$CMD" | awk -f "$HERE/tokenize.awk")
exit 0
