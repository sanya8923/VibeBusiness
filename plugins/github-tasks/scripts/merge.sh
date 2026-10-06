#!/usr/bin/env bash
# Слияние принятого PR: merge.sh <номер PR>
#
# Сливает только PR, у которого последний вердикт в комментариях — «Вердикт: Принято»
# (вердикт пишет приёмщик, см. PROCESS.md, раздел «Приёмка»). Принимает только PR в
# базовую ветку проекта. Если база — не основная ветка репозитория, GitHub не закроет
# задачу по «Closes #N», и её закрывает этот скрипт.
#
# Код выхода: 0 — слито, 1 — отказ или ошибка.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PR=${1:-}
gt_require_number "$PR"
gt_require_config
R=$(gt_repo)
BASE=$(gt_base)

info=$(gh pr view "$PR" -R "$R" --json state,baseRefName,headRefName,isCrossRepository \
  -q '[.state, .baseRefName, .headRefName, (.isCrossRepository | tostring)] | join("\u001f")')
IFS=$'\x1f' read -r state base head cross <<<"$info"
[ "$state" = OPEN ] || gt_die "PR #$PR не открыт (состояние: $state)"
[ "$base" = "$BASE" ] || gt_die "PR #$PR идёт в «$base», а базовая ветка проекта — «$BASE»"
# PR из форка процесс не ведёт: ветка задачи живёт в этом репозитории. Такой PR сливает
# человек вручную, после собственной проверки.
[ "$cross" = false ] || gt_die "PR #$PR пришёл из другого репозитория (форка) — сливать его скриптом нельзя"

# Вердикт засчитывается только от тех, у кого есть право записи в репозиторий: в
# открытом репозитории комментарий «Вердикт: Принято» может написать кто угодно.
verdict=$(gh pr view "$PR" -R "$R" --json comments \
  -q '[.comments[] | select(.authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR") | .body | select(startswith("Вердикт:"))] | last // ""')
case "$verdict" in
  "Вердикт: Принято"*) ;;
  "") gt_die "в PR #$PR нет вердикта приёмки — сначала приёмка" ;;
  *)  gt_die "последний вердикт в PR #$PR — не «Принято»" ;;
esac

issue=$(gh pr view "$PR" -R "$R" --json body -q .body \
  | grep -oiE '(closes|fixes|resolves) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)

gh pr merge "$PR" -R "$R" --merge >/dev/null
echo "PR #$PR слит в $BASE"

if [ -n "$issue" ]; then
  if [ "$BASE" != "$(gt_default_branch)" ]; then
    gh issue close "$issue" -R "$R" \
      -c "Принято и слито в \`$BASE\` через #$PR. GitHub закрывает задачи по «Closes» только при слиянии в основную ветку, поэтому задачу закрыл скрипт слияния." >/dev/null 2>&1
    echo "задача #$issue закрыта"
  fi
  # У закрытой задачи метка статуса больше не нужна — иначе на ней навсегда висит «in-review».
  "$(dirname "$0")/status.sh" "$issue" none >/dev/null || echo "метку статуса с задачи #$issue снять не удалось" >&2
fi

# Удаляем только ветку задачи этого PR: «issue-N» с номером из «Closes».
if [ -n "$issue" ] && [ "$head" = "issue-$issue" ]; then
  gh api -X DELETE "repos/$R/git/refs/heads/$head" >/dev/null 2>&1 && echo "ветка $head удалена" || true
fi
