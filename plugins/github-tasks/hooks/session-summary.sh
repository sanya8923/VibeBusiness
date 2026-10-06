#!/usr/bin/env bash
# SessionStart-хук: короткая сводка — какие задачи в работе и на приёмке.
# Попадает в контекст сессии, чтобы Claude не взял чужую задачу и видел, что ждёт
# приёмки. Не больше 5 строк. Нет сети или gh — молчит.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

CWD=$(hk_field cwd)
[ -n "$CWD" ] || CWD=$PWD
root=$(hk_root "$CWD")
[ -n "$root" ] && hk_enabled "$root" || exit 0
command -v gh >/dev/null 2>&1 || exit 0

label() {  # имя метки по ключу из файла настроек, иначе по умолчанию
  local v
  v=$(sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$root/.claude/github-tasks.json" | head -1)
  echo "${v:-$2}"
}
INP=$(label in_progress in-progress)
REV=$(label in_review in-review)

list() {  # номера и заголовки открытых задач с меткой $1, через «; »
  (cd "$root" && gh issue list --state open --label "$1" --limit 20 \
    --json number,title -q '[.[] | "#\(.number) \(.title)"] | join("; ")' 2>/dev/null)
}
cut80() { local s="$1"; [ ${#s} -gt 300 ] && s="${s:0:297}..."; echo "$s"; }

inp=$(list "$INP") || exit 0
rev=$(list "$REV") || exit 0
echo "github-tasks — задачи проекта сейчас:"
echo "- в работе ($INP): $(cut80 "${inp:-нет}")"
echo "- на приёмке ($REV): $(cut80 "${rev:-нет}")"
echo "Задачу с исполнителем не брать; новую — только через scripts/claim.sh."
