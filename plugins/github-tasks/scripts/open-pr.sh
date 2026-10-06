#!/usr/bin/env bash
# PR задачи: open-pr.sh <номер задачи> [файл с отчётом исполнителя]
#
# Отправляет ветку issue-N на GitHub, открывает PR в базовую ветку с «Closes #N»
# и отчётом, переводит задачу в статус «на приёмке». Если PR по ветке уже открыт
# (после возврата с приёмки) — новый не создаёт, только отправляет коммиты и снова
# ставит статус. Незакоммиченные правки в рабочей копии — отказ: в PR они не попадут.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

N=${1:-}
gt_require_number "$N"
gt_require_config
REPORT=${2:-}
R=$(gt_repo)
BASE=$(gt_base)
WT=$(gt_worktree_path "$N")
BR="issue-$N"

[ -d "$WT" ] || gt_die "нет рабочей копии $WT — сначала worktree.sh $N"
[ -z "$(git -C "$WT" status --porcelain)" ] || gt_die "в рабочей копии есть незакоммиченные правки — закоммить файлы задачи поимённо"
[ -z "$REPORT" ] || [ -f "$REPORT" ] || gt_die "нет файла отчёта: $REPORT"

git -C "$WT" fetch -q origin "$BASE"
ahead=$(git -C "$WT" rev-list --count "origin/$BASE..HEAD")
[ "$ahead" -gt 0 ] || gt_die "в ветке $BR нет коммитов поверх $BASE — нечего отдавать на приёмку"

git -C "$WT" push -q -u origin "$BR"

pr=$(gh pr list -R "$R" --head "$BR" --state open --json number -q '.[0].number // empty')
if [ -z "$pr" ]; then
  title=$(gh issue view "$N" -R "$R" --json title -q .title)
  body=$(mktemp)
  { echo "Closes #$N"; echo; [ -n "$REPORT" ] && cat "$REPORT"; } > "$body"
  url=$(gh pr create -R "$R" --base "$BASE" --head "$BR" --title "$title" --body-file "$body")
  rm -f "$body"
else
  url=$(gh pr view "$pr" -R "$R" --json url -q .url)
  if [ -n "$REPORT" ]; then gh pr comment "$pr" -R "$R" --body-file "$REPORT" >/dev/null; fi
  echo "PR уже открыт — отправлены новые коммиты" >&2
fi

"$(dirname "$0")/status.sh" "$N" in_review >/dev/null
echo "$url"
