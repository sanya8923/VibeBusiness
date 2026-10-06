#!/usr/bin/env bash
# Смена статуса задачи: status.sh <номер задачи> <статус>
#
# Статус — ключ (ready, in_progress, in_review, blocked, owner_decision) или имя метки
# из настроек; none снимает все метки статуса. Ставит одну метку и снимает остальные
# метки статуса — у задачи не бывает двух статусов сразу.
#
# Возврат в ready означает «задача свободна»: снимаем исполнителя и удаляем
# комментарии-заявки, иначе свежая заявка прежней сессии помешает следующему захвату.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

N=${1:-}
gt_require_number "$N"
gt_require_config
KEY=$(gt_status_key "${2:-}")
R=$(gt_repo)

current=$(gh issue view "$N" -R "$R" --json labels -q '[.labels[].name] | join(",")')
target=""
[ "$KEY" = none ] || target=$(gt_label "$KEY")

remove=()
for k in $GT_STATUS_KEYS; do
  l=$(gt_label "$k")
  [ "$l" = "$target" ] && continue
  case ",$current," in *",$l,"*) remove+=("$l") ;; esac
done

# Сначала снимаем старые метки статуса, потом ставим новую: при одном вызове с
# --add-label и --remove-label GitHub ставит новую раньше, чем снимает старую, и около
# секунды у задачи два статуса. Момент без статуса допустим, двух сразу — нет.
rm_args=()
[ ${#remove[@]} -gt 0 ] && rm_args+=(--remove-label "$(IFS=,; echo "${remove[*]}")")

if [ "$KEY" = ready ]; then
  logins=$(gh issue view "$N" -R "$R" --json assignees -q '[.assignees[].login] | join(",")')
  [ -n "$logins" ] && rm_args+=(--remove-assignee "$logins")
  for c in $(gh api --paginate "repos/$R/issues/$N/comments" \
      -q '.[] | select(.body | startswith("<!-- github-tasks:claim ")) | .id'); do
    gh api -X DELETE "repos/$R/issues/comments/$c" >/dev/null 2>&1 || true
  done
fi

[ ${#rm_args[@]} -gt 0 ] && gh issue edit "$N" -R "$R" "${rm_args[@]}" >/dev/null
[ -n "$target" ] && gh issue edit "$N" -R "$R" --add-label "$target" >/dev/null
echo "задача #$N: ${target:-без статуса}"
