#!/usr/bin/env bash
# Stop-хук: напоминает о работе, которая есть только на этом диске.
# Незапушенные коммиты и незакоммиченные правки в рабочих копиях задач
# (.claude/worktrees/) пропадут для следующей сессии и для приёмщика.
# Ничего не блокирует — только сообщение пользователю.
#
# Событие Stop наступает после каждого ответа Claude, а не только в конце сессии: у
# события конца сессии (SessionEnd) вывод пользователю не показывается. Поэтому
# напоминание может появляться и посреди работы — это нормально, пока работа не отправлена.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

CWD=$(hk_field cwd)
[ -n "$CWD" ] || CWD=$PWD
root=$(hk_root "$CWD")
[ -n "$root" ] && hk_enabled "$root" || exit 0

notes=""
while IFS= read -r line; do
  case "$line" in worktree\ *) wt=${line#worktree } ;; *) continue ;; esac
  [ -d "$wt" ] || continue
  name=${wt#"$root"/}; [ "$wt" = "$root" ] && name="основная копия"
  case "$wt" in "$root"|"$root"/.claude/worktrees/*) ;; *) continue ;; esac
  if [ "$wt" != "$root" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    notes="$notes\n- $name: есть незакоммиченные правки"
  fi
  if git -C "$wt" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] && notes="$notes\n- $name: незапушенных коммитов — $ahead"
  elif [ "$wt" != "$root" ]; then
    br=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo "?")
    notes="$notes\n- $name: ветка $br ни разу не отправлена на GitHub"
  fi
done < <(git -C "$root" worktree list --porcelain 2>/dev/null)

[ -n "$notes" ] || exit 0
msg=$(printf 'github-tasks: работа есть только на этом диске:%b\nОтправь её (push) или оставь передачу в задаче — иначе следующая сессия её не увидит.' "$notes")
# JSON собираем без внешних утилит: экранируем \ и " и переводы строк.
esc=$(printf '%s' "$msg" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if (NR>1) print "\\n"; print}')
printf '{"systemMessage": "%s"}\n' "$esc"
