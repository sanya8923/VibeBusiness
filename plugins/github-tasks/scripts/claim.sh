#!/usr/bin/env bash
# Захват задачи: claim.sh <номер задачи>
#
# Несколько сессий Claude под одним аккаунтом GitHub неразличимы по исполнителю,
# поэтому захват идёт через комментарий-заявку: из одновременных заявок побеждает
# заявка с наименьшим номером комментария (GitHub выдаёт их по возрастанию).
# Заявка старше 10 минут считается брошенной — сессия упала до того, как поставила метку.
# Правило целиком — PROCESS.md, раздел «Захват задачи».
#
# Код выхода: 0 — задача взята, 3 — занято или не готова, 1 — ошибка.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

N=${1:-}
gt_require_number "$N"
gt_require_config
R=$(gt_repo)
READY=$(gt_label ready)
INP=$(gt_label in_progress)
SID=${CLAUDE_CODE_SESSION_ID:-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')}
STALE=${GT_CLAIM_STALE_SECONDS:-600}
MARK='<!-- github-tasks:claim '

info=$(gh issue view "$N" -R "$R" --json state,labels,assignees \
  -q '[.state, ([.labels[].name] | join(",")), (.assignees | length)] | @tsv')
IFS=$'\t' read -r state labels assignees <<<"$info"
[ "$state" = OPEN ] || gt_busy "задача #$N закрыта"
[ "$assignees" = 0 ] || gt_busy "у задачи #$N уже есть исполнитель"
case ",$labels," in
  *",$READY,"*) ;;
  *) gt_busy "у задачи #$N нет метки $READY — постановка не готова или задачу уже взяли" ;;
esac

cid=$(gh api "repos/$R/issues/$N/comments" \
  -f body="${MARK}session=$SID -->
Беру в работу (сессия \`$SID\`)." -q .id)

# Даём одновременной заявке другой сессии успеть появиться в выдаче.
sleep "${GT_CLAIM_WAIT_SECONDS:-3}"

# Своя заявка участвует всегда: при коротком сроке годности она сама могла бы
# «устареть» за время ожидания, и сессия проиграла бы самой себе.
first=$(gh api --paginate "repos/$R/issues/$N/comments" \
  -q ".[] | select(.body | startswith(\"$MARK\")) | select(.id == $cid or (now - (.created_at | fromdateiso8601)) < $STALE) | .id" \
  | sort -n | head -1)

if [ "$first" != "$cid" ]; then
  gh api -X DELETE "repos/$R/issues/comments/$cid" >/dev/null || true
  gt_busy "задачу #$N одновременно взяла другая сессия"
fi

gh issue edit "$N" -R "$R" --add-assignee @me --add-label "$INP" --remove-label "$READY" >/dev/null

# Победитель убирает все чужие заявки, включая брошенные: после захвата в задаче
# остаётся одна заявка, и по ней видно, чья задача.
for c in $(gh api --paginate "repos/$R/issues/$N/comments" \
    -q ".[] | select(.body | startswith(\"$MARK\")) | .id"); do
  [ "$c" = "$cid" ] || gh api -X DELETE "repos/$R/issues/comments/$c" >/dev/null || true
done
echo "задача #$N взята (сессия $SID)"
