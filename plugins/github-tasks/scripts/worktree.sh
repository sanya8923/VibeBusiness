#!/usr/bin/env bash
# Рабочая копия задачи: worktree.sh <номер задачи>
#
# Своя копия у каждой сессии: две сессии не правят одни и те же файлы на диске.
# Копия — .claude/worktrees/issue-N внутри репозитория, ветка issue-N от свежей
# базовой ветки. Если копия или ветка уже есть — это продолжение работы, их и берём.
# Печатает путь к рабочей копии последней строкой.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

N=${1:-}
gt_require_number "$N"
gt_require_config
ROOT=$(gt_root)
BASE=$(gt_base)
WT=$(gt_worktree_path "$N")
BR="issue-$N"

# Папку рабочих копий прячем от git. Через info/exclude, а не .gitignore: правка
# .gitignore оставила бы незакоммиченное изменение в основной копии. В .gitignore
# её вносит настройка проекта.
if ! git -C "$ROOT" check-ignore -q .claude/worktrees/x 2>/dev/null; then
  echo ".claude/worktrees/" >> "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
fi

if [ -d "$WT" ]; then
  echo "рабочая копия уже есть — продолжение работы" >&2
  echo "$WT"; exit 0
fi

git -C "$ROOT" fetch -q origin "$BASE"
mkdir -p "$(dirname "$WT")"
if git -C "$ROOT" ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
  git -C "$ROOT" fetch -q origin "$BR"
  if git -C "$ROOT" show-ref -q --verify "refs/heads/$BR"; then
    git -C "$ROOT" worktree add -q "$WT" "$BR"
  else
    git -C "$ROOT" worktree add -q --track -b "$BR" "$WT" "origin/$BR"
  fi
  echo "ветка $BR уже есть на GitHub — продолжение работы" >&2
elif git -C "$ROOT" show-ref -q --verify "refs/heads/$BR"; then
  git -C "$ROOT" worktree add -q "$WT" "$BR"
else
  git -C "$ROOT" worktree add -q -b "$BR" "$WT" "origin/$BASE"
fi
echo "$WT"
